/**
 * Minimal mmap/munmap compatibility layer for Windows (MinGW).
 *
 * Maps POSIX mmap(PROT_READ, MAP_PRIVATE) to the Windows
 * CreateFileMapping + MapViewOfFile API.  Only the subset used
 * by t2sz is implemented.
 */
#ifndef MMAN_COMPAT_H
#define MMAN_COMPAT_H

#ifdef _WIN32

#include <windows.h>
#include <io.h>       /* _get_osfhandle */
#include <stddef.h>

#define PROT_READ   1
#define MAP_PRIVATE 2
#define MAP_FAILED  ((void*)-1)

static inline void *mmap(void *addr, size_t length, int prot, int flags,
                         int fd, long long offset)
{
    (void)addr; (void)prot; (void)flags; (void)offset;

    HANDLE fh = (HANDLE)_get_osfhandle(fd);
    if(fh == INVALID_HANDLE_VALUE)
        return MAP_FAILED;

    HANDLE mapping = CreateFileMappingA(fh, NULL, PAGE_READONLY, 0, 0, NULL);
    if(!mapping)
        return MAP_FAILED;

    void *ptr = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, length);
    CloseHandle(mapping);   /* view keeps the mapping alive */
    return ptr ? ptr : MAP_FAILED;
}

static inline int munmap(void *addr, size_t length)
{
    (void)length;
    return UnmapViewOfFile(addr) ? 0 : -1;
}

#else /* POSIX */
#include <sys/mman.h>
#endif

#endif /* MMAN_COMPAT_H */
