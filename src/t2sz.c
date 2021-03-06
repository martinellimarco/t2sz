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
#include <sys/mman.h>
#include <zstd.h>

typedef struct {                /* byte offset */
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
    uint8_t* ptr = (uint8_t*)header;
    uint32_t ac = 0;

    while (ptr < (uint8_t*)&header->chksum) ac += *ptr++;

    ac += 8*0x20;//8 ASCII spaces
    ptr+= 8;

    while (ptr < (uint8_t*)header+512) ac += *ptr++;

    return ac;
}

bool isTarHeader(TarHeader* header){
    uint32_t chksum = checksum(header);

    char* buf = malloc(7);
    memcpy(buf, header->chksum, 6);
    buf[6] = 0;
    uint32_t hdrChksum = strtol(buf, NULL, 8);
    free(buf);

    return chksum == hdrChksum;
}

typedef struct {
    //input parameters
    const char* inFilename;
    char *outFilename;
    uint8_t level;
    size_t minBlockSize;
    bool verbose;

    //input buffer
    size_t inBuffSize;
    uint8_t* inBuff;

    //output buffer
    FILE* outFile;
    size_t outBuffSize;
    void* outBuff;

    //compression context
    ZSTD_CCtx* cctx;
} Context;

Context* newContext(){
    Context* ctx = malloc(sizeof(Context));
    memset(ctx, 0, sizeof(Context));
    ctx->level = 22;
    return ctx;
}

void prepareInput(Context *ctx){
    int fd = open(ctx->inFilename, O_RDONLY, 0);
    if(fd < 0){
        fprintf(stderr, "ERROR: Unable to open '%s'\n", ctx->inFilename);
        exit(1);
    }
    ctx->inBuffSize = lseek(fd, 0L, SEEK_END);

    ctx->inBuff = (uint8_t*)mmap(NULL, ctx->inBuffSize, PROT_READ, MAP_PRIVATE, fd, 0);
    if(ctx->inBuff == MAP_FAILED){
        fprintf(stderr, "ERROR: Unable to mmap '%s'\n", ctx->inFilename);
        exit(1);
    }
    close(fd);
}

void prepareOutput(Context *ctx){
    ctx->outFile = fopen(ctx->outFilename, "wb");
    if(!ctx->outFile){
        fprintf(stderr, "ERROR: Cannot open output file for writing\n");
        exit(1);
    }
    ctx->outBuffSize = ZSTD_CStreamOutSize();
    ctx->outBuff = malloc(ctx->outBuffSize);
}

void prepareCctx(Context *ctx){
    ctx->cctx = ZSTD_createCCtx();
    if(ctx->cctx == NULL){
        fprintf(stderr, "ERROR: Cannot create ZSTD CCtx\n");
        exit(1);
    }

    size_t err;
    err = ZSTD_CCtx_setParameter(ctx->cctx, ZSTD_c_compressionLevel, ctx->level);
    if(ZSTD_isError(err)){
        fprintf(stderr, "ERROR: Cannot set compression level: %s\n", ZSTD_getErrorName(err));
        exit(1);
    }

    err = ZSTD_CCtx_setParameter(ctx->cctx, ZSTD_c_checksumFlag, 1);
    if(ZSTD_isError(err)){
        fprintf(stderr, "ERROR: Cannot set checksum flag: %s\n", ZSTD_getErrorName(err));
        exit(1);
    }
}

void compressFile(Context *ctx){
    prepareInput(ctx);

    prepareOutput(ctx);

    prepareCctx(ctx);

    size_t tarHeaderIdx = 0;
    uint8_t* readBuff = ctx->inBuff;

    bool lastChunk = false;
    while(!lastChunk) {
        size_t blockSize = 0;
        do{
            if(ctx->inBuff[tarHeaderIdx]){//tar ends with null headers that we can skip
                TarHeader *header = (TarHeader *)&ctx->inBuff[tarHeaderIdx];
                if(isTarHeader(header)){
                    size_t size = strtol(header->size, NULL, 8);

                    size_t toNextHeader = (size_t)(ceil((float)size / 512.0) * 512) + 512;

                    tarHeaderIdx += toNextHeader;
                    blockSize += toNextHeader;

                    if(ctx->verbose){
                        fprintf(stderr, "+ %s (%ld)\n", header->name, size);
                    }
                }else{
                    fprintf(stderr, "ERROR: Invalid tar header\n");
                    exit(-1);
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

        ZSTD_CCtx_setPledgedSrcSize(ctx->cctx, blockSize);
        if(ctx->verbose){
            fprintf(stderr, "# END OF BLOCK (%lu)\n\n", blockSize);
        }

        if(readBuff+blockSize > ctx->inBuff+ctx->inBuffSize){
            fprintf(stderr, "FATAL ERROR: This is a bug. Please, report it.\n");
            exit(-1);
        }

        ZSTD_inBuffer input = {readBuff, blockSize, 0 };
        size_t remaining;
        mode_t mode;
        do {
            ZSTD_outBuffer output = {ctx->outBuff, ctx->outBuffSize, 0 };
            mode = input.pos < input.size ? ZSTD_e_continue : ZSTD_e_end;
            remaining = ZSTD_compressStream2(ctx->cctx, &output , &input, mode);
            if(ZSTD_isError(remaining)){
                fprintf(stderr, "ERROR: Can't compress stream: %s\n", ZSTD_getErrorName(remaining));
                exit(1);
            }
            fwrite(ctx->outBuff, 1, output.pos, ctx->outFile);
        } while (mode==ZSTD_e_continue || remaining>0);

        readBuff += blockSize;
    }

    ZSTD_freeCCtx(ctx->cctx);
    fclose(ctx->outFile);
    free(ctx->outBuff);
    munmap(ctx->inBuff, ctx->inBuffSize);
}

static char* getOutFilename(const char* inFilename){
    const size_t size = strlen(inFilename) + 5;
    void* const buff = malloc(size);
    memset(buff, 0, size);
    strcat(buff, inFilename);
    strcat(buff, ".zst");
    return (char*)buff;
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

    fprintf(stderr,
            "t2sz: tar 2 seekable zstd.\n"
            "It will compress a tar archive with Zstandard keeping each file in a different frame, unless `-s` is used.\n"
            "This allows fast seeking and extraction of a single file without decompressing the whole archive.\n"
            "The compressed archive can be uncompressed with any Zstandard tool, including zstd.\n"
            "\nTo take advantage of seeking see the following projects:\n"
            "\tC/C++ library:  https://github.com/martinellimarco/libzstd-seek\n"
            "\tPython library: https://github.com/martinellimarco/indexed_zstd\n"
            "\tFUSE mount:     https://github.com/mxmlnkn/ratarmount\n"
            "\n"
            "Usage: %1$s [OPTIONS...] [TAR ARCHIVE]\n"
            "\n"
            "Examples:\n"
            "\t%1$s archive.tar                            Compress archive.tar to archive.tar.zst\n"
            "\t%1$s archive.tar -o output.tar.zst          Compress archive.tar to output.tar.zst\n"
            "\t%1$s archive.tar -o /dev/stdout             Compress archive.tar to standard output\n"
            "\n"
            "Options:\n"
            "\t-l [1..22]         Set compression level, from 1 (lower) to 22 (highest). Default is 22.\n"
            "\t-o FILENAME        Output file name.\n"
            "\t-s SIZE            Minimum size of an input block, in bytes.\n"
            "\t                   A block is composed by one or more whole files. A file is never truncated.\n"
            "\t                   If not specified one block will contain exactly one file, no matter the file size.\n"
            "\t                   Each block is compressed to a zstd frame but if the archive has a lot of small files\n"
            "\t                   having a file per block doesn't compress very well. With this you can set a trade off.\n"
            "\t                   The greater is SIZE the smaller will be the archive at the expense of the seek speed.\n"
            "\t                   SIZE may be followed by the following multiplicative suffixes:\n"
            "\t                       k/K/KiB = 1024\n"
            "\t                       M/MiB = 1024*1024\n"
            "\t                       kB/KB = 1000\n"
            "\t                       MB = 1000*1000\n"
            "\t-v                 Verbose. List the elements in the tar archive and their size.\n"
            "\t-f                 Overwrite output without prompting.\n"
            "\t-h                 Print this help.\n"
            "\t-V                 Print the version.\n"
            "\n",
            name);
    version();
    exit(0);
}

bool strEndsWith(const char * str, const char * suf){
    size_t strLen = strlen(str);
    size_t sufLen = strlen(suf);

    return (strLen >= sufLen) && (0 == strcmp(str + (strLen - sufLen), suf));
}

int main(int argc, char **argv){
    Context *ctx = newContext();
    bool overwrite = false;
    char* executable = argv[0];

    int ch;
    while ((ch = getopt(argc, argv, "l:o:s:Vfvh")) != -1) {
        switch (ch) {
            case 'l':
                ctx->level = atoi(optarg);
                if(ctx->level<1 || ctx->level>22){
                    usage(executable, "ERROR: Invalid level. Must be between 1 and 22.");
                }
                break;
            case 'o':
                ctx->outFilename = optarg;
                break;
            case 's': {
                size_t multiplier = 1;
                if(strEndsWith(optarg, "k") || strEndsWith(optarg, "K") || strEndsWith(optarg, "KiB")){
                    multiplier = 1024;
                }else if(strEndsWith(optarg, "M") || strEndsWith(optarg, "MiB")){
                    multiplier = 1024*1024;
                }else if(strEndsWith(optarg, "kB") || strEndsWith(optarg, "KB")){
                    multiplier = 1000;
                }else if(strEndsWith(optarg, "MB")){
                    multiplier = 1000*1000;
                }
                ctx->minBlockSize = atoi(optarg) * multiplier;
                if(ctx->minBlockSize < multiplier){
                    usage(executable, "ERROR: Invalid block size");
                }
                break;
            }
            case 'v':
                ctx->verbose = true;
                break;
            case 'f':
                overwrite = true;
                break;
            case 'V':
                version();
                exit(0);
            case 'h':
            default:
                usage(executable, NULL);
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

    ctx->inFilename = argv[0];

    if(access(ctx->inFilename, F_OK ) != 0){
        fprintf(stderr, "%s: File not found\n", ctx->inFilename);
        return 1;
    }

    if(ctx->outFilename == NULL){
        ctx->outFilename = getOutFilename(ctx->inFilename);
    }

    if(!overwrite && access(ctx->outFilename, F_OK ) == 0){
        char ans;
        fprintf(stderr, "%s already exists. Overwrite? [y/N]: ", ctx->outFilename);
        int res = scanf(" %c", &ans);
        if(res && ans!='y'){
            return 0;
        }
    }

    compressFile(ctx);

    free(ctx);

    return 0;
}
