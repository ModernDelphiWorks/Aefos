/*
 * libvterm_unity.c - Unity build for Delphi {$L} embedding (Demand #24 / ESP-024)
 *
 * Rationale: Delphi's {$L} linker makes a single-pass symbol resolution.
 * The 9 libvterm translation units have circular cross-references that cannot
 * be satisfied in any single linear order. Compiling all 9 units into one
 * object eliminates all inter-object references, leaving only CRT-shim
 * EXTDEFs (_malloc, _memcpy, etc.) that the Delphi binding unit satisfies.
 *
 * Static-name conflicts were resolved by renaming the conflicting symbols
 * directly in the source files (state_putglyph_fn, state_erase_fn,
 * screen_putglyph_fn, screen_erase_fn, screen_setpenattr_fn,
 * pen_setpenattr_fn). utf8.h was given #pragma once to prevent double
 * inclusion (keyboard.c and screen.c both include it).
 *
 * Usage:
 *   bcc32c -c -I../include -I. -o ../obj/libvterm_unity.obj libvterm_unity.c
 */

#include "vterm.c"
#include "parser.c"
#include "state.c"
#include "screen.c"
#include "pen.c"
#include "keyboard.c"
#include "mouse.c"
#include "encoding.c"
#include "unicode.c"
