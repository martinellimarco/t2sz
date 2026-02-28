//SPDX-License-Identifier: GPL-3.0-or-later
/* ******************************************************************
 * t2sz
 * Copyright (c) 2020, Martinelli Marco
 *
 * You can contact the author at :
 * - Email: marco+t2sz@13byte.com
 * - Source repository : https://github.com/martinellimarco/t2sz
 *
 * This source code is licensed under the GPLv3 (found in the LICENSE
 * file in the root directory of this source tree).
****************************************************************** */

#include <stdio.h>
#include <getopt.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <zstd.h>

typedef struct __attribute__((__packed__)) { /* byte offset */
    char name[100];               /*   0 */
    char mode[8];                 /* 100 */
    char uid[8];                  /* 108 */
    char gid[8];                  /* 116 */
    char size[12];                /* 124 */
    char mtime[12];               /* 136 */
    char chksum[8];               /* 148 */
    char typeflag;                /* 156 */
    char linkname[100];           /* 157 */
    char magic[6];                /* 257 */
    char version[2];              /* 263 */
    char uname[32];               /* 265 */
    char gname[32];               /* 297 */
    char devmajor[8];             /* 329 */
    char devminor[8];             /* 337 */
    char prefix[155];             /* 345 */
    /* 500 */
} TarHeader;

uint32_t checksum(TarHeader* header){
    const uint8_t* ptr = (uint8_t*)header;
    uint32_t ac = 0;

    while (ptr < (uint8_t*)&header->chksum) ac += *ptr++;

    ac += 8*0x20;//8 ASCII spaces
    ptr+= 8;

    while (ptr < (uint8_t*)header+512) ac += *ptr++;

    return ac;
}

bool isTarHeader(TarHeader* header){
    const uint32_t chksum = checksum(header);

    char buf[7];
    memcpy(buf, header->chksum, 6);
    buf[6] = 0;
    const uint32_t hdrChksum = strtoul(buf, NULL, 8);

    if(chksum != hdrChksum){
        fprintf(stderr, "ERROR: Mismatching checksum. Expected 0x%08x but found 0x%08x.\n", chksum, hdrChksum);
        return false;
    }

    return true;
}

typedef struct {
    uint32_t compressedSize;
    uint32_t decompressedSize;
} SeekTableEntry;

typedef struct {
    //input parameters
    const char* inFilename;
    char *outFilename;
    uint8_t level;
    size_t minBlockSize;
    size_t maxBlockSize;
    bool verbose;
    bool rawMode;     //non-tar mode
    bool stdinMode;   //input is "-" (stdin)
    bool stdoutMode;  //output is "-" (stdout)
    uint32_t workers;

    //input buffer
    size_t inBuffSize;
    uint8_t* inBuff;

    //output buffer
    FILE* outFile;
    size_t outBuffSize;
    void* outBuff;

    //compression context
    ZSTD_CCtx* cctx;

    //seek table
    SeekTableEntry* seekTable;
    size_t seekTableLen;
    size_t seekTableCap;
    bool skipSeekTable;
} Context;

bool isLittleEndian(){
    volatile int x = 1;
    return *(char*)(&x) == 1;
}

void writeLE32(void* dst, const uint32_t data){
    if(isLittleEndian()){
        memcpy(dst, &data, sizeof(data));
    }else{
        const uint32_t swap = ((data & 0xFF000000) >> 24) |
                        ((data & 0x00FF0000) >> 8)  |
                        ((data & 0x0000FF00) << 8)  |
                        ((data & 0x000000FF) << 24);
        memcpy(dst, &swap, sizeof(swap));
    }
}

void writeSeekTable(const Context *ctx){
    uint8_t buf[4];
    //Skippable_Magic_Number
    writeLE32(buf, ZSTD_MAGIC_SKIPPABLE_START | 0xE);
    fwrite(buf, 4, 1, ctx->outFile);
    
    //Frame_Size
    writeLE32(buf, (uint32_t)ctx->seekTableLen*8 + 9);
    fwrite(buf, 4, 1, ctx->outFile);
        
    if(ctx->verbose){
        fprintf(stderr, "\n---- seek table ----\n");
        fprintf(stderr, "decompressed\tcompressed\n");
    }

    //Seek_Table_Entries
    for (size_t i = 0; i < ctx->seekTableLen; i++) {
        const SeekTableEntry* e = &ctx->seekTable[i];

        //Compressed_Size
        writeLE32(buf, e->compressedSize);
        fwrite(buf, 4, 1, ctx->outFile);

        //Decompressed_Size
        writeLE32(buf, e->decompressedSize);
        fwrite(buf, 4, 1, ctx->outFile);

        if(ctx->verbose){
            fprintf(stderr, "%u\t%u\n", e->decompressedSize, e->compressedSize);
        }
    }

    //Seek_Table_Footer
    //Number_Of_Frames
    writeLE32(buf, (uint32_t)ctx->seekTableLen);
    fwrite(buf, 4, 1, ctx->outFile);
    
    //Seek_Table_Descriptor
    buf[0] = 0;
    fwrite(buf, 1, 1, ctx->outFile);
    
    //Seekable_Magic_Number
    writeLE32(buf, 0x8F92EAB1);
    fwrite(buf, 4, 1, ctx->outFile);
}

static void seekTableEnsureCap(Context* ctx, const size_t needed) {
    if (ctx->seekTableCap >= needed) return;

    size_t newCap = ctx->seekTableCap ? ctx->seekTableCap : 1024; // start cap
    while (newCap < needed) newCap *= 2;

    SeekTableEntry* p = realloc(ctx->seekTable, newCap * sizeof(SeekTableEntry));
    if (!p) {
        fprintf(stderr, "ERROR: Out of memory while growing seek table\n");
        exit(EXIT_FAILURE);
    }
    ctx->seekTable = p;
    ctx->seekTableCap = newCap;
}

void seekTableAdd(Context* ctx, const uint64_t compressedSize, const uint64_t decompressedSize){
    if(ctx->skipSeekTable){
        return;
    }

    // entry size uint32 + numFrames uint32
    if(ctx->seekTableLen + 1 >= 0x8000000U){
        ctx->skipSeekTable = true;
        fprintf(stderr, "Warning: Too many frames. Unable to generate the seek table.\n");
        return;
    }
    if(decompressedSize >= 0x80000000U){
        ctx->skipSeekTable = true;
        fprintf(stderr, "Warning: Input frame too big. Unable to generate the seek table.\n");
        return;
    }
    if(compressedSize >= 0x100000000ULL){
        ctx->skipSeekTable = true;
        fprintf(stderr, "Warning: Compressed frame too big. Unable to generate the seek table.\n");
        return;
    }

    seekTableEnsureCap(ctx, ctx->seekTableLen + 1);

    ctx->seekTable[ctx->seekTableLen].compressedSize   = (uint32_t)compressedSize;
    ctx->seekTable[ctx->seekTableLen].decompressedSize = (uint32_t)decompressedSize;
    ctx->seekTableLen++;
}

Context* newContext(){
    Context* ctx = malloc(sizeof(Context));
    if(!ctx){
        fprintf(stderr, "ERROR: Out of memory allocating new context\n");
        exit(EXIT_FAILURE);
    }
    memset(ctx, 0, sizeof(Context));
    ctx->level = 3;
    return ctx;
}

void prepareInput(Context *ctx){
    if(ctx->stdinMode){
        // The stdin path is handled by compressStdinRaw()/compressStdinTar().
        return;
    }

    const int fd = open(ctx->inFilename, O_RDONLY, 0);
    if(fd < 0){
        fprintf(stderr, "ERROR: Unable to open '%s'\n", ctx->inFilename);
        exit(EXIT_FAILURE);
    }

    const off_t end = lseek(fd, 0, SEEK_END);
    if(end < 0){
        fprintf(stderr, "ERROR: Unable to seek '%s'\n", ctx->inFilename);
        close(fd);
        exit(EXIT_FAILURE);
    }
    if(end == 0){
        fprintf(stderr, "ERROR: Empty input file '%s'\n", ctx->inFilename);
        close(fd);
        exit(EXIT_FAILURE);
    }
    ctx->inBuffSize = (size_t)end;

    ctx->inBuff = (uint8_t*)mmap(NULL, ctx->inBuffSize, PROT_READ, MAP_PRIVATE, fd, 0);
    if(ctx->inBuff == MAP_FAILED){
        fprintf(stderr, "ERROR: Unable to mmap '%s'\n", ctx->inFilename);
        close(fd);
        exit(EXIT_FAILURE);
    }
    close(fd);
}

void prepareOutput(Context *ctx){
    if(ctx->stdoutMode){
        ctx->outFile = stdout;
    }else{
        ctx->outFile = fopen(ctx->outFilename, "wb");
        if(!ctx->outFile){
            fprintf(stderr, "ERROR: Cannot open output file for writing\n");
            exit(EXIT_FAILURE);
        }
    }
    ctx->outBuffSize = ZSTD_CStreamOutSize();
    ctx->outBuff = malloc(ctx->outBuffSize);
    if(!ctx->outBuff){
        fprintf(stderr, "ERROR: Out of memory allocating output buffer\n");
        exit(EXIT_FAILURE);
    }
}

void prepareCctx(Context *ctx){
    ctx->cctx = ZSTD_createCCtx();
    if(ctx->cctx == NULL){
        fprintf(stderr, "ERROR: Cannot create ZSTD CCtx\n");
        exit(EXIT_FAILURE);
    }

    size_t err;
    err = ZSTD_CCtx_setParameter(ctx->cctx, ZSTD_c_compressionLevel, ctx->level);
    if(ZSTD_isError(err)){
        fprintf(stderr, "ERROR: Cannot set compression level: %s\n", ZSTD_getErrorName(err));
        exit(EXIT_FAILURE);
    }

    err = ZSTD_CCtx_setParameter(ctx->cctx, ZSTD_c_checksumFlag, 1);
    if(ZSTD_isError(err)){
        fprintf(stderr, "ERROR: Cannot set checksum flag: %s\n", ZSTD_getErrorName(err));
        exit(EXIT_FAILURE);
    }

    if(ctx->workers){
        err = ZSTD_CCtx_setParameter(ctx->cctx, ZSTD_c_nbWorkers, (int32_t)ctx->workers);
        if(ZSTD_isError(err)){
            fprintf(stderr, "ERROR: Multi-thread is supported only with libzstd >= 1.5.0 or on older versions compiled with ZSTD_MULTITHREAD. Reverting to single-thread.\n");
            ctx->workers = 0;
            ZSTD_CCtx_setParameter(ctx->cctx, ZSTD_c_nbWorkers, (int32_t)ctx->workers);
        }
    }
}

static void zstdResetFrame(const Context *ctx){
    const size_t err = ZSTD_CCtx_reset(ctx->cctx, ZSTD_reset_session_only);
    if(ZSTD_isError(err)){
        fprintf(stderr, "ERROR: Can't reset ZSTD session: %s\n", ZSTD_getErrorName(err));
        exit(EXIT_FAILURE);
    }
}

static void zstdSetPledged(const Context *ctx, const unsigned long long size, const bool known){
    const size_t err = ZSTD_CCtx_setPledgedSrcSize(ctx->cctx, known ? size : ZSTD_CONTENTSIZE_UNKNOWN);
    if (ZSTD_isError(err)) {
        fprintf(stderr, "ERROR: Can't set pledged size: %s\n", ZSTD_getErrorName(err));
        exit(EXIT_FAILURE);
    }
}

static uint64_t zstdCompressBufferToFrame(const Context *ctx, const uint8_t *src, const size_t srcSize){
    // Compress exactly one frame from a memory buffer, with known size.
    zstdResetFrame(ctx);
    zstdSetPledged(ctx, srcSize, true);

    ZSTD_inBuffer input = { src, srcSize, 0 };
    uint64_t compressedSize = 0;

    while(true){
        ZSTD_outBuffer output = { ctx->outBuff, ctx->outBuffSize, 0 };
        const ZSTD_EndDirective mode = (input.pos < input.size) ? ZSTD_e_continue : ZSTD_e_end;

        const size_t remaining = ZSTD_compressStream2(ctx->cctx, &output, &input, mode);
        if(ZSTD_isError(remaining)){
            fprintf(stderr, "ERROR: Can't compress stream: %s\n", ZSTD_getErrorName(remaining));
            exit(EXIT_FAILURE);
        }
        compressedSize += fwrite(ctx->outBuff, 1, output.pos, ctx->outFile);

        if(mode == ZSTD_e_end && remaining == 0){
            break;
        }
    }

    return compressedSize;
}

static uint64_t zstdEndFrame(const Context *ctx){
    uint64_t compressedSize = 0;

    // Some libzstd builds don't like input == NULL. Use an explicit empty buffer.
    ZSTD_inBuffer empty = { NULL, 0, 0 };

    while(true){
        ZSTD_outBuffer output = { ctx->outBuff, ctx->outBuffSize, 0 };
        const size_t remaining = ZSTD_compressStream2(ctx->cctx, &output, &empty, ZSTD_e_end);
        if(ZSTD_isError(remaining)){
            fprintf(stderr, "ERROR: Can't end frame: %s\n", ZSTD_getErrorName(remaining));
            exit(EXIT_FAILURE);
        }
        compressedSize += fwrite(ctx->outBuff, 1, output.pos, ctx->outFile);
        if(remaining == 0) {
            break;
        }
    }
    return compressedSize;
}

static void compressStdinRaw(Context *ctx){
    // Two behaviours:
    // - If -s is set (minBlockSize > 0): read exactly one frame worth of bytes into a frame buffer,
    //   then compress it as an independent frame with correct pledged size.
    // - If -s is not set: stream into a single frame (pledged unknown), matching original "whole file" raw behaviour.

    if(ctx->minBlockSize == 0){
        // Single-frame streaming, pledged unknown
        zstdResetFrame(ctx);
        zstdSetPledged(ctx, 0, false);

        const size_t inChunk = ZSTD_CStreamInSize();
        uint8_t *inBuf = malloc(inChunk);
        if (!inBuf) {
            fprintf(stderr, "ERROR: Out of memory allocating stdin buffer\n");
            exit(EXIT_FAILURE);
        }

        uint64_t decompressedSize = 0;
        uint64_t compressedSize = 0;

        while(true){
            const size_t n = fread(inBuf, 1, inChunk, stdin);
            if(n > 0){
                decompressedSize += n;

                ZSTD_inBuffer input = { inBuf, n, 0 };
                while(input.pos < input.size){
                    ZSTD_outBuffer output = { ctx->outBuff, ctx->outBuffSize, 0 };
                    const size_t remaining = ZSTD_compressStream2(ctx->cctx, &output, &input, ZSTD_e_continue);
                    if(ZSTD_isError(remaining)){
                        fprintf(stderr, "ERROR: Can't compress stream: %s\n", ZSTD_getErrorName(remaining));
                        free(inBuf);
                        exit(EXIT_FAILURE);
                    }
                    compressedSize += fwrite(ctx->outBuff, 1, output.pos, ctx->outFile);
                }
            }

            if (n == 0) {
                if (ferror(stdin)) {
                    fprintf(stderr, "ERROR: Read error on stdin\n");
                    free(inBuf);
                    exit(EXIT_FAILURE);
                }
                // EOF
                break;
            }
        }

        compressedSize += zstdEndFrame(ctx);

        seekTableAdd(ctx, compressedSize, decompressedSize);

        free(inBuf);
        return;
    }

    // Fixed-size frames: buffer exactly one frame at a time (bounded memory = minBlockSize)
    const size_t frameSize = ctx->minBlockSize;
    uint8_t *frameBuf = malloc(frameSize);
    if(!frameBuf){
        fprintf(stderr, "ERROR: Out of memory allocating %zu-byte frame buffer\n", frameSize);
        exit(EXIT_FAILURE);
    }

    while(true){
        size_t got = 0;
        while(got < frameSize){
            const size_t n = fread(frameBuf + got, 1, frameSize - got, stdin);
            if(n > 0){
                got += n;
                continue;
            }
            if(ferror(stdin)){
                fprintf(stderr, "ERROR: Read error on stdin\n");
                free(frameBuf);
                exit(EXIT_FAILURE);
            }
            // EOF
            break;
        }

        if(got == 0){
            break; // no more data
        }

        const uint64_t compressedSize = zstdCompressBufferToFrame(ctx, frameBuf, got);
        seekTableAdd(ctx, compressedSize, got);

        if(got < frameSize) {
            break; // last partial frame (EOF)
        }
    }

    free(frameBuf);
}

static bool isZeroTarBlock(const uint8_t *b){
    for(size_t i = 0; i < 512; i++){
        if(b[i] != 0) return false;
    }
    return true;
}

static void readExactStdin(uint8_t *dst, const size_t n){
    size_t got = 0;
    while(got < n){
        const size_t r = fread(dst + got, 1, n - got, stdin);
        if(r == 0){
            if(feof(stdin)){
                fprintf(stderr, "ERROR: Unexpected EOF on stdin\n");
            }else{
                fprintf(stderr, "ERROR: Read error on stdin\n");
            }
            exit(EXIT_FAILURE);
        }
        got += r;
    }
}

static void startFrameUnknown(const Context *ctx, uint64_t *frameIn, uint64_t *frameOut, bool *frameOpen){
    zstdResetFrame(ctx);
    zstdSetPledged(ctx, 0, false); // unknown size
    *frameIn = 0;
    *frameOut = 0;
    *frameOpen = true;
}

static void endFrameAndRecord(Context *ctx, const uint64_t frameIn, uint64_t frameOut, bool *frameOpen){
    if(!*frameOpen){
        return;
    }

    frameOut += zstdEndFrame(ctx);

    seekTableAdd(ctx, frameOut, frameIn);
    *frameOpen = false;
}

static void pushBytesTar(Context *ctx, const uint8_t *src, const size_t n, uint64_t *frameIn, uint64_t *frameOut, bool *frameOpen){
    size_t off = 0;
    while(off < n){
        if(!*frameOpen){
            startFrameUnknown(ctx, frameIn, frameOut, frameOpen);
        }

        // If maxBlockSize is set, never exceed it.
        size_t canWrite = n - off;
        if(ctx->maxBlockSize){
            if(*frameIn >= ctx->maxBlockSize){
                // current frame full -> close and open next
                endFrameAndRecord(ctx, *frameIn, *frameOut, frameOpen);
                continue;
            }
            const size_t left = ctx->maxBlockSize - (size_t)(*frameIn);
            if(canWrite > left) canWrite = left;
        }

        ZSTD_inBuffer in = { src + off, canWrite, 0 };
        while(in.pos < in.size){
            ZSTD_outBuffer out = { ctx->outBuff, ctx->outBuffSize, 0 };
            const size_t rem = ZSTD_compressStream2(ctx->cctx, &out, &in, ZSTD_e_continue);
            if(ZSTD_isError(rem)){
                fprintf(stderr, "ERROR: Can't compress stream: %s\n", ZSTD_getErrorName(rem));
                exit(EXIT_FAILURE);
            }
            *frameOut += fwrite(ctx->outBuff, 1, out.pos, ctx->outFile);
        }

        *frameIn += canWrite;
        off += canWrite;

        // If we exactly filled maxBlockSize, close immediately (split).
        if(ctx->maxBlockSize && *frameIn >= ctx->maxBlockSize){
            endFrameAndRecord(ctx, *frameIn, *frameOut, frameOpen);
        }
    }
}

static void compressStdinTar(Context *ctx){
    // Default tar behaviour matches mmap-path:
    // - if minBlockSize==0: "one file per frame"
    // - if minBlockSize>0: aggregate whole files until >= min, then close at file boundary
    // - if maxBlockSize>0: split so frames never exceed max (may split inside a file)

    const size_t inChunk = ZSTD_CStreamInSize();
    uint8_t *chunkBuf = malloc(inChunk);
    if(!chunkBuf){
        fprintf(stderr, "ERROR: Out of memory allocating tar stdin chunk buffer\n");
        exit(EXIT_FAILURE);
    }

    uint8_t hdrBlock[512];

    uint64_t frameIn = 0, frameOut = 0;
    bool frameOpen = false;

    while(true){
        // Read next 512-byte tar header/block
        const size_t r = fread(hdrBlock, 1, 512, stdin);
        if(r == 0){
            if(ferror(stdin)){
                fprintf(stderr, "ERROR: Read error on stdin\n");
                free(chunkBuf);
                exit(EXIT_FAILURE);
            }
            // EOF
            break;
        }
        if(r != 512){
            // partial header => truncated stream
            fprintf(stderr, "ERROR: Truncated tar header on stdin\n");
            free(chunkBuf);
            exit(EXIT_FAILURE);
        }

        // Always include the 512-byte block in the stream (like your mmap logic does).
        pushBytesTar(ctx, hdrBlock, 512, &frameIn, &frameOut, &frameOpen);

        if(isZeroTarBlock(hdrBlock)){
            if(ctx->verbose){
                fprintf(stderr, "+ <null>\n");
            }

            // In "one file per frame" mode, also close after a null block (matches mmap behaviour when -s is 0)
            if(ctx->minBlockSize == 0 && frameOpen){
                endFrameAndRecord(ctx, frameIn, frameOut, &frameOpen);
            }
            continue;
        }

        TarHeader *header = (TarHeader*)hdrBlock;
        if(!isTarHeader(header)){
            fprintf(stderr, "ERROR: Invalid tar header. If this is not a tar archive use raw mode (-r)\n");
            free(chunkBuf);
            exit(EXIT_FAILURE);
        }

        const size_t fileSize = strtoul(header->size, NULL, 8);

        // pad to 512
        size_t padded = fileSize;
        const size_t mod = padded % 512;
        if(mod) padded = padded - mod + 512;

        if(ctx->verbose){
            fprintf(stderr, "+ %s (%zu)\n", header->name, padded);
        }

        // Stream payload+pads: read exactly 'padded' bytes from stdin, push through compressor,
        // respecting maxBlockSize splitting.
        size_t remaining = padded;
        while(remaining > 0){
            const size_t take = remaining > inChunk ? inChunk : remaining;
            readExactStdin(chunkBuf, take);
            pushBytesTar(ctx, chunkBuf, take, &frameIn, &frameOut, &frameOpen);
            remaining -= take;
        }

        // End-of-file boundary: decide whether to close frame
        if(ctx->minBlockSize == 0){
            // one file per frame
            if(frameOpen){
                endFrameAndRecord(ctx, frameIn, frameOut, &frameOpen);
            }
        }else{
            // aggregated blocks: close only at file boundary when >= minBlockSize
            if(frameOpen && frameIn >= ctx->minBlockSize){
                endFrameAndRecord(ctx, frameIn, frameOut, &frameOpen);
            }
        }
    }

    // If stream ended without the 2 zero blocks (truncated tar), still close whatever was open.
    if(frameOpen){
        endFrameAndRecord(ctx, frameIn, frameOut, &frameOpen);
    }

    free(chunkBuf);
}

static void cleanupCompression(const Context *ctx){
    if(!ctx->skipSeekTable){
        writeSeekTable(ctx);
    }
    free(ctx->seekTable);
    ZSTD_freeCCtx(ctx->cctx);
    if(!ctx->stdoutMode){
        fclose(ctx->outFile);
    }else{
        fflush(ctx->outFile);
    }
    free(ctx->outBuff);
}

void compressFile(Context *ctx){
    prepareOutput(ctx);

    prepareCctx(ctx);

    if(ctx->stdinMode){
        if(ctx->rawMode){
            compressStdinRaw(ctx);
        }else{
            compressStdinTar(ctx);
        }

        cleanupCompression(ctx);
    }else{
        prepareInput(ctx);

        size_t tarHeaderIdx = 0;
        uint8_t* readBuff = ctx->inBuff;

        bool lastChunk = false;
        size_t residual = 0;
        while(!lastChunk) {
            size_t blockSize = 0;
            if(ctx->rawMode){
                if(ctx->minBlockSize){
                    blockSize = ctx->minBlockSize;
                    if(readBuff+blockSize > ctx->inBuff+ctx->inBuffSize){
                        blockSize = ctx->inBuff+ctx->inBuffSize - readBuff;
                        lastChunk = true;
                    }
                }else{
                    blockSize = ctx->inBuffSize;
                    lastChunk = true;
                }
            }else{
                do{
                    if(residual){
                        if(residual > ctx->maxBlockSize){
                            blockSize = ctx->maxBlockSize;
                            residual = residual - ctx->maxBlockSize;
                        }else{
                            blockSize = residual;
                            residual = 0;
                        }
                    }else if(ctx->inBuff[tarHeaderIdx]){//tar ends with null headers that we can skip
                        TarHeader *header = (TarHeader *)&ctx->inBuff[tarHeaderIdx];
                        if(isTarHeader(header)){
                            size_t size = strtoul(header->size, NULL, 8);

                            const size_t mod = size%512;
                            if(mod){
                                size = size - mod + 512;
                            }
                            const size_t toNextHeader  = size + 512;

                            tarHeaderIdx += toNextHeader;
                            blockSize += toNextHeader;

                            if(ctx->maxBlockSize && blockSize > ctx->maxBlockSize){
                                residual = blockSize - ctx->maxBlockSize;
                                blockSize = ctx->maxBlockSize;
                            }

                            if(ctx->verbose){
                                fprintf(stderr, "+ %s (%zu)\n", header->name, size);
                            }
                        }else{
                            fprintf(stderr, "ERROR: Invalid tar header. If this is not a tar archive use raw mode (-r)\n");
                            exit(EXIT_FAILURE);
                        }
                    }else{
                        if(ctx->verbose){
                            fprintf(stderr, "+ <null>\n");
                        }
                        tarHeaderIdx+=512;
                        blockSize += 512;
                    }
                    lastChunk = tarHeaderIdx >= ctx->inBuffSize;
                }while(blockSize < ctx->minBlockSize && !lastChunk);
            }

            zstdSetPledged(ctx, blockSize, true);
            if(ctx->verbose){
                fprintf(stderr, "# END OF BLOCK (%lu, %lu)\n\n", blockSize, tarHeaderIdx);
            }

            if(readBuff+blockSize > ctx->inBuff+ctx->inBuffSize){
                fprintf(stderr, "FATAL ERROR: This is a bug. Please, report it.\n");
                exit(EXIT_FAILURE);
            }

            ZSTD_inBuffer input = {readBuff, blockSize, 0 };
            size_t remaining;
            ZSTD_EndDirective mode;
            uint64_t compressedSize = 0;
            do {
                ZSTD_outBuffer output = {ctx->outBuff, ctx->outBuffSize, 0 };
                mode = input.pos < input.size ? ZSTD_e_continue : ZSTD_e_end;
                remaining = ZSTD_compressStream2(ctx->cctx, &output , &input, mode);
                if(ZSTD_isError(remaining)){
                    fprintf(stderr, "ERROR: Can't compress stream: %s\n", ZSTD_getErrorName(remaining));
                    exit(EXIT_FAILURE);
                }
                compressedSize += fwrite(ctx->outBuff, 1, output.pos, ctx->outFile);
            } while (mode==ZSTD_e_continue || remaining>0);

            seekTableAdd(ctx, compressedSize, blockSize);

            readBuff += blockSize;
        }

        cleanupCompression(ctx);
        munmap(ctx->inBuff, ctx->inBuffSize);
    }
}

static char* getOutFilename(const char* inFilename){
    const size_t size = strlen(inFilename) + 5;
    void* const buff = malloc(size);
    if(!buff){
        fprintf(stderr, "ERROR: Out of memory allocating output filename buffer\n");
        exit(EXIT_FAILURE);
    }
    memset(buff, 0, size);
    strcat(buff, inFilename);
    strcat(buff, ".zst");
    return buff;
}

void version(){
    fprintf(stderr,
            "t2sz version %s\n"
            "Copyright (C) 2020 Marco Martinelli <marco+t2sz@13byte.com>\n"
            "https://github.com/martinellimarco/t2sz\n"
            "This software is distributed under the GPLv3 License\n"
            "THIS SOFTWARE IS PROVIDED \"AS IS\" WITHOUT ANY WARRANTY\n",
            VERSION);
}

void usage(const char *name, const char *str){
    if(str){
        fprintf(stderr, "%s\n\n", str);
    }

    fprintf(stdout,
            "t2sz: tar 2 seekable zstd.\n"
            "It compresses a file into a seekable zstd, splitting the file into multiple frames.\n"
            "If the file is a tar archive it compresses each file in the archive into an independent frame, hence the name.\n"
            "It operates in two modes. Tar archive mode and raw mode.\n"
            "By default it runs in tar archive mode for files ending with .tar, unless -r is specified.\n"
            "For all other files it runs in raw mode.\n"
            "In tar archive mode it compresses the archive keeping each file in a different frame, unless -s or -S is used.\n"
            "This allows fast seeking and extraction of a single file without decompressing the whole archive.\n"
            "The compressed archive can be decompressed with any Zstandard tool, including zstd.\n"
            "\nTo take advantage of seeking see the following projects:\n"
            "\tC/C++ library:  https://github.com/martinellimarco/libzstd-seek\n"
            "\tPython library: https://github.com/martinellimarco/indexed_zstd\n"
            "\tFUSE mount:     https://github.com/mxmlnkn/ratarmount\n"
            "\n"
            "Usage: %1$s [OPTIONS...] [TAR ARCHIVE | -]\n"
            "\n"
            "Use '-' as the input filename to read from standard input.\n"
            "\n"
            "Examples:\n"
            "\t%1$s any.file -s 10M                        Compress any.file to any.file.zst, each input block will be of 10M\n"
            "\t%1$s archive.tar                            Compress archive.tar to archive.tar.zst\n"
            "\t%1$s archive.tar -o output.tar.zst          Compress archive.tar to output.tar.zst\n"
            "\t%1$s archive.tar -o -                       Compress archive.tar to standard output\n"
            "\t%1$s -r - -o out.zst                        Compress stdin (raw mode) to out.zst\n"
            "\t%1$s - -o out.tar.zst                       Compress tar from stdin to out.tar.zst\n"
            "\t%1$s -r - -o -                              Compress stdin to stdout (raw mode)\n"
            "\n"
            "Options:\n"
            "\t-l [1..22]         Set compression level, from 1 (lower) to 22 (highest). Default is 3.\n"
            "\t-o FILENAME        Output file name. Use '-' to write to standard output.\n"
            "\t                   When reading from stdin ('-') and -o is omitted, output defaults to stdout.\n"
            "\t-s SIZE            In raw mode: the exact size of each input block, except the last one.\n"
            "\t                   In tar mode: the minimum size of an input block, in bytes.\n"
            "\t                                A block is composed by one or more whole files.\n"
            "\t                                A file is never split unless -S is used.\n"
            "\t                                If not specified one block will contain exactly one file, no matter the file size.\n"
            "\t                                Each block is compressed to a zstd frame but if the archive has a lot of small files\n"
            "\t                                having a file per block doesn't compress very well. With this you can set a trade off.\n"
            "\t                   The greater is SIZE the smaller will be the archive at the expense of the seek speed.\n"
            "\t                   SIZE may be followed by the following multiplicative suffixes:\n"
            "\t                       k/K/KiB = 1024\n"
            "\t                       M/MiB = 1024^2\n"
            "\t                       G/GiB = 1024^3\n"
            "\t                       kB/KB = 1000\n"
            "\t                       MB = 1000^2\n"
            "\t                       GB = 1000^3\n"
            "\t-S SIZE            In raw mode: it is ignored.\n"
            "\t                   In tar mode: the maximum size of an input block, in bytes.\n"
            "\t                   Unlike -s this option may split big files in smaller chunks.\n"
            "\t                   Remember that each block is compressed independently and a small value here will result in a bigger archive.\n"
            "\t                   -S can be used together with -s but MUST be greater or equal to its value.\n"
            "\t                   If -S and -s are equal the input block will be of exactly that size, if there is enough input data.\n"
            "\t                   Like -s SIZE may be followed by one of the multiplicative suffixes described above.\n"
            "\t-T [1..N]          Number of thread to spawn. It improves compression speed but cost more memory. Default is single thread.\n"
            "\t                   It requires libzstd >= 1.5.0 or an older version compiler with ZSTD_MULTITHREAD.\n"
            "\t                   If `-s` or `-S` are too small it is possible that a lower number of threads will be used.\n"
            "\t-r                 Raw mode or non-tar mode. Treat tar archives as regular files, without any special handling.\n"
            "\t-j                 Do not generate a seek table.\n"
            "\t-v                 Verbose. List the elements in the tar archive and their size.\n"
            "\t-f                 Overwrite output without prompting.\n"
            "\t-h                 Print this help.\n"
            "\t-V                 Print the version.\n"
            "\n",
            name);
    version();
    exit(!str ? EXIT_SUCCESS : EXIT_FAILURE);
}

bool strEndsWith(const char * str, const char * suf){
    const size_t strLen = strlen(str);
    const size_t sufLen = strlen(suf);

    return (strLen >= sufLen) && (0 == strcmp(str + (strLen - sufLen), suf));
}

size_t decodeMultiplier(const char *arg){
    size_t multiplier = 1;
    if(strEndsWith(arg, "k") || strEndsWith(arg, "K") || strEndsWith(arg, "KiB")){
        multiplier = 1024;
    }else if(strEndsWith(arg, "M") || strEndsWith(arg, "MiB")){
        multiplier = 1024*1024;
    }else if(strEndsWith(arg, "G") || strEndsWith(arg, "GiB")){
        multiplier = 1024*1024*1024;
    }else if(strEndsWith(arg, "kB") || strEndsWith(arg, "KB")){
        multiplier = 1000;
    }else if(strEndsWith(arg, "MB")){
        multiplier = 1000*1000;
    }else if(strEndsWith(arg, "GB")){
        multiplier = 1000*1000*1000;
    }
    return multiplier;
}

int main(int argc, char **argv){
    Context *ctx = newContext();
    bool overwrite = false;
    const char* executable = argv[0];

    int ch;
    while((ch = getopt(argc, argv, "l:o:s:S:T:rjVfvh")) != -1){
        switch(ch){
            case 'l': {
                char *endptr;
                errno = 0;
                const long val = strtol(optarg, &endptr, 10);
                if(endptr == optarg || *endptr != '\0' || errno == ERANGE || val < 1 || val > 22){
                    usage(executable, "ERROR: Invalid level. Must be between 1 and 22.");
                }
                ctx->level = (int32_t)val;
                break;
            }
            case 'o':
                ctx->outFilename = optarg;
                break;
            case 's': {
                const size_t multiplier = decodeMultiplier(optarg);
                char *endptr;
                errno = 0;
                const long val = strtol(optarg, &endptr, 10);
                if(endptr == optarg || errno == ERANGE || val < 1){
                    usage(executable, "ERROR: Invalid block size");
                }
                ctx->minBlockSize = (size_t)val * multiplier;
                break;
            }
            case 'S': {
                const size_t multiplier = decodeMultiplier(optarg);
                char *endptr;
                errno = 0;
                const long val = strtol(optarg, &endptr, 10);
                if(endptr == optarg || errno == ERANGE || val < 1){
                    usage(executable, "ERROR: Invalid block size");
                }
                ctx->maxBlockSize = (size_t)val * multiplier;
                break;
            }
            case 'T': {
                char *endptr;
                errno = 0;
                const long val = strtol(optarg, &endptr, 10);
                if(endptr == optarg || *endptr != '\0' || errno == ERANGE || val < 1 || val > UINT32_MAX){
                    usage(executable, "ERROR: Invalid number of threads. Must be greater than 0.");
                }
                ctx->workers = (uint32_t)val;
                break;
            }
            case 'r':
                ctx->rawMode = true;
                break;
            case 'j':
                ctx->skipSeekTable = true;
                break;
            case 'v':
                ctx->verbose = true;
                break;
            case 'f':
                overwrite = true;
                break;
            case 'V':
                version();
                exit(EXIT_SUCCESS);
            case 'h':
                usage(executable, NULL);
                break;
            default:
                usage(executable, "ERROR: Unknown option");
                break;
        }
    }
    argc -= optind;
    argv += optind;

    if(argc < 1){
        usage(executable, "Not enough arguments");
    }else if(argc > 1){
        usage(executable, "Too many arguments");
    }

    if(ctx->maxBlockSize && ctx->maxBlockSize < ctx->minBlockSize){
        usage(executable, "The maximum block size can't be smaller than the minimum one");
    }

    ctx->inFilename = argv[0];

    // Stdin mode: "-" as the input filename reads from standard input.
    if(strcmp(ctx->inFilename, "-") == 0){
        ctx->stdinMode = true;
    }

    // Auto-detect raw mode from filename suffix only for real files.
    // When reading from stdin there is no filename to inspect; the user must
    // pass -r explicitly if raw mode is desired (default: tar mode).
    if(!ctx->rawMode && !ctx->stdinMode){
        ctx->rawMode = !strEndsWith(ctx->inFilename, "tar");
    }

    // File existence check — not applicable for stdin.
    if(!ctx->stdinMode && access(ctx->inFilename, F_OK) != 0){
        fprintf(stderr, "%s: File not found\n", ctx->inFilename);
        free(ctx);
        return EXIT_FAILURE;
    }

    // Determine the output destination.
    char *outFilenameToFree = NULL;
    if(ctx->outFilename == NULL){
        if(ctx->stdinMode){
            // stdin input with no explicit -o: write to stdout.
            ctx->stdoutMode = true;
        }else{
            outFilenameToFree = ctx->outFilename = getOutFilename(ctx->inFilename);
        }
    }else if(strcmp(ctx->outFilename, "-") == 0){
        // -o - explicitly requested: write to stdout.
        ctx->stdoutMode = true;
    }

    // Overwrite prompt — skipped when writing to stdout (nothing to overwrite).
    // ctx->inBuff is NULL here; prepareInput() is called inside compressFile().
    if(!ctx->stdoutMode && !overwrite && access(ctx->outFilename, F_OK) == 0){
        char ans;
        fprintf(stderr, "%s already exists. Overwrite? [y/N]: ", ctx->outFilename);
        const int res = scanf(" %c", &ans);
        if(res && ans != 'y'){
            free(outFilenameToFree);
            free(ctx);
            return EXIT_SUCCESS;
        }
    }

    compressFile(ctx);

    free(outFilenameToFree);
    free(ctx);

    return EXIT_SUCCESS;
}
