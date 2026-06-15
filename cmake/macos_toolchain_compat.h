#pragma once

#if defined(__APPLE__) && defined(__clang__)
#  ifndef __has_builtin
#    define __has_builtin(x) 0
#  endif

#  if !__has_builtin(__builtin_ctzg)
#    define __builtin_ctzg(value, ...)                                                                  \
        ((sizeof(value) <= sizeof(unsigned int))     ? __builtin_ctz((unsigned int)(value))             \
         : (sizeof(value) <= sizeof(unsigned long))  ? __builtin_ctzl((unsigned long)(value))           \
                                                     : __builtin_ctzll((unsigned long long)(value)))
#  endif

#  if !__has_builtin(__builtin_clzg)
#    define __builtin_clzg(value, ...)                                                                  \
        ((sizeof(value) <= sizeof(unsigned int))     ? __builtin_clz((unsigned int)(value))             \
         : (sizeof(value) <= sizeof(unsigned long))  ? __builtin_clzl((unsigned long)(value))           \
                                                     : __builtin_clzll((unsigned long long)(value)))
#  endif

#  if (defined(__aarch64__) || defined(__arm64__)) && __has_include(<arm_acle.h>)
#    include <arm_acle.h>
#  endif
#endif
