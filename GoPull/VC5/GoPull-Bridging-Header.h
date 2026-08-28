//
//  GoPull-Bridging-Header.h
//  GoPull
//
//  Exposes GoPro's VC-5 decoder to Swift. See VC5/README.md for what is
//  vendored and why.
//
//  The standard headers come first deliberately: the vendored headers use
//  uint16_t and friends without including <stdint.h> themselves, which the
//  library's own build gets away with and a bridging header does not.
//

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#import "vc5_decoder.h"
#import "gpr_buffer.h"
