/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under both the BSD-style license (found in the
 * LICENSE file in the root directory of this source tree) and the GPLv2 (found
 * in the COPYING file in the root directory of this source tree).
 * You may select, at your option, one of the above-listed licenses.
 */

#ifndef PLATFORM_H_MODULE
#define PLATFORM_H_MODULE

/* **************************************
*  Detect 64-bit OS
****************************************/
#if defined __arm64__ || defined __aarch64__ || defined __ARM64_ARCH_8__                                           /* ARM 64-bit */    \
  || defined _LP64 || defined __LP64__                                                                                                 \
  || (defined __SIZEOF_POINTER__ && __SIZEOF_POINTER__ == 8) /* gcc */
#  if !defined(__64BIT__)
#    define __64BIT__  1
#  endif
#endif


/* *********************************************************
*  Turn on Large Files support (>4GB) for 32-bit Linux/Unix
***********************************************************/
#if !defined(__64BIT__) || defined(__MINGW32__)    /* No point defining Large file for 64 bit but MinGW-w64 requires it */
#  if !defined(_FILE_OFFSET_BITS)
#    define _FILE_OFFSET_BITS 64                   /* turn off_t into a 64-bit type for ftello, fseeko */
#  endif
#  if !defined(_LARGEFILE_SOURCE)                  /* obsolete macro, replaced with _FILE_OFFSET_BITS */
#    define _LARGEFILE_SOURCE 1                    /* Large File Support extension (LFS) - fseeko, ftello */
#  endif
#  if defined(_AIX) || defined(__hpux)
#    define _LARGE_FILES                           /* Large file support on 32-bits AIX and HP-UX */
#  endif
#endif


/* ************************************************************
*  Detect POSIX version
*  PLATFORM_POSIX_VERSION = 0 for non-Unix e.g. Windows
*  PLATFORM_POSIX_VERSION = 1 for Unix-like but non-POSIX
*  PLATFORM_POSIX_VERSION > 1 is equal to found _POSIX_VERSION
*  Value of PLATFORM_POSIX_VERSION can be forced on command line
***************************************************************/
#ifndef PLATFORM_POSIX_VERSION

#  if (defined(__APPLE__) && defined(__MACH__)) || defined(__SVR4) || defined(_AIX) || defined(__hpux) /* POSIX.1-2001 (SUSv3) conformant */
     /* exception rule : force posix version to 200112L,
      * note: it's better to use unistd.h's _POSIX_VERSION whenever possible */
#    define PLATFORM_POSIX_VERSION 200112L

/* try to determine posix version through official unistd.h's _POSIX_VERSION (https://pubs.opengroup.org/onlinepubs/7908799/xsh/unistd.h.html).
 * note : there is no simple way to know in advance if <unistd.h> is present or not on target system,
 * Posix specification mandates its presence and its content, but target system must respect this spec.
 * It's necessary to _not_ #include <unistd.h> whenever target OS is not unix-like
 * otherwise it will block preprocessing stage.
 * The following list of build macros tries to "guess" if target OS is likely unix-like, and therefore can #include <unistd.h>
 */
#  elif !defined(_WIN32) \
     && ( defined(__unix__) || defined(__unix) \
       || defined(_QNX_SOURCE) || defined(__midipix__) || defined(__VMS) || defined(__HAIKU__) )

#    if defined(__linux__) || defined(__linux) || defined(__CYGWIN__)
#      ifndef _POSIX_C_SOURCE
#        define _POSIX_C_SOURCE 200809L  /* feature test macro : https://www.gnu.org/software/libc/manual/html_node/Feature-Test-Macros.html */
#      endif
#    endif
#    include <unistd.h>  /* declares _POSIX_VERSION */
#    if defined(_POSIX_VERSION)  /* POSIX compliant */
#      define PLATFORM_POSIX_VERSION _POSIX_VERSION
#    else
#      define PLATFORM_POSIX_VERSION 1
#    endif

#    ifdef __UCLIBC__
#     ifndef __USE_MISC
#      define __USE_MISC /* enable st_mtim on uclibc */
#     endif
#    endif

#  else  /* non-unix target platform (like Windows) */
#    define PLATFORM_POSIX_VERSION 0
#  endif

#endif   /* PLATFORM_POSIX_VERSION */


#if PLATFORM_POSIX_VERSION > 1
   /* glibc < 2.26 may not expose struct timespec def without this.
    * See issue #1920. */
#  ifndef _ATFILE_SOURCE
#    define _ATFILE_SOURCE
#  endif
#endif


/*-*********************************************
*  Detect if isatty() and fileno() are available
*
*  Note: Use UTIL_isConsole() for the zstd CLI
*  instead, as it allows faking is console for
*  testing.
************************************************/
#if (defined(__linux__) && (PLATFORM_POSIX_VERSION > 1)) \
 || (PLATFORM_POSIX_VERSION >= 200112L)
#  include <unistd.h>   /* isatty */
#  include <stdio.h>    /* fileno */
#  define IS_CONSOLE(stdStream) isatty(fileno(stdStream))
#else
#  define IS_CONSOLE(stdStream) 0
#endif


/******************************
*  OS-specific IO behaviors
******************************/
#define SET_BINARY_MODE(file)
#define SET_SPARSE_FILE_MODE(file)


#ifndef ZSTD_SPARSE_DEFAULT
#  if (defined(__APPLE__) && defined(__MACH__))
#    define ZSTD_SPARSE_DEFAULT 0
#  else
#    define ZSTD_SPARSE_DEFAULT 1
#  endif
#endif


#ifndef ZSTD_START_SYMBOLLIST_FRAME
#  ifdef __linux__
#    define ZSTD_START_SYMBOLLIST_FRAME 2
#  elif defined __APPLE__
#    define ZSTD_START_SYMBOLLIST_FRAME 4
#  else
#    define ZSTD_START_SYMBOLLIST_FRAME 0
#  endif
#endif


#ifndef ZSTD_SETPRIORITY_SUPPORT
   /* mandates presence of <sys/resource.h> and support for setpriority() : https://man7.org/linux/man-pages/man2/setpriority.2.html */
#  define ZSTD_SETPRIORITY_SUPPORT (PLATFORM_POSIX_VERSION >= 200112L)
#endif


#ifndef ZSTD_NANOSLEEP_SUPPORT
   /* mandates support of nanosleep() within <time.h> : https://man7.org/linux/man-pages/man2/nanosleep.2.html */
#  if (defined(__linux__) && (PLATFORM_POSIX_VERSION >= 199309L)) \
   || (PLATFORM_POSIX_VERSION >= 200112L)
#     define ZSTD_NANOSLEEP_SUPPORT 1
#  else
#     define ZSTD_NANOSLEEP_SUPPORT 0
#  endif
#endif

#endif /* PLATFORM_H_MODULE */
