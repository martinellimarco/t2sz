[![Build Status](https://github.com/martinellimarco/t2sz/workflows/Test%20Build/badge.svg)](https://github.com/martinellimarco/t2sz/actions)
[![License](https://img.shields.io/badge/license-GPLv3-green.svg)](https://github.com/martinellimarco/t2sz/blob/main/LICENSE)
[![t2sz](https://snapcraft.io/t2sz/badge.svg)](https://snapcraft.io/t2sz)

# t2sz
It compress a file into a seekable [zstd](https://github.com/facebook/zstd) splitting the file into multiple frames.

If the file is a tar archive it compress each file in the archive into an independent frame, hence the name: tar 2 seekable zstd.

It operates in two modes. Tar archive mode and raw mode.

By default it runs in tar archive mode for files ending with `.tar`, unless `-r` is specified.

For all other files it runs in raw mode.

In tar archive mode it compress the archive keeping each file in a different frame, unless `-s` or `-S` is used.

This allows fast seeking and extraction of a single file without decompressing the whole archive.

When `-s SIZE` is used in tar mode, if the size of the file being compressed into a block is less than `SIZE` then another one will be added in the same block, and so on until the sum of the sizes of all files packed together is at least `SIZE`. A file will be never spltted as `SIZE` is just a minimum value.

When `-s SIZE` is used in raw mode then it defines exactly the input block size and bigger inputs will be split in blocks of this size accordingly. If there isn't enough input data the last block will be smaller.

When `-S SIZE` is used, files bigger than `SIZE` will be splitted in blocks of `SIZE` length. It is available only in tar mode and ignored in raw mode.

The compressed archive can be decompressed with any Zstandard tool, including `zstd`.

To take advantage of seeking see the following projects:
- C/C++ library:  [libzstd-seek](https://github.com/martinellimarco/libzstd-seek)
- Python library: [indexed_zstd](https://github.com/martinellimarco/indexed_zstd)
- FUSE mount:     [ratarmount](https://github.com/mxmlnkn/ratarmount)


# Build

You'll need `libzstd-dev`

```bash
sudo apt install libzstd-dev
```

```bash
git clone https://github.com/martinellimarco/t2sz
mkdir t2sz/build
cd t2sz/build
cmake .. -DCMAKE_BUILD_TYPE="Release"
make
```

Install with

```bash
sudo make install
```

Or if you want a debian package you can run

```bash
cpack
```

then install it with

```bash
sudo dpkg -i t2sz*.deb
```

# Usage

```commandline
Usage: t2sz [OPTIONS...] [TAR ARCHIVE]

Examples:
        t2sz any.file -s 10M                        Compress any.file to any.file.zst, each frame will be of 10M
        t2sz archive.tar                            Compress archive.tar to archive.tar.zst
        t2sz archive.tar -o output.tar.zst          Compress archive.tar to output.tar.zst
        t2sz archive.tar -o /dev/stdout             Compress archive.tar to standard output

Options:
        -l [1..22]         Set compression level, from 1 (lower) to 22 (highest). Default is 3.
        -o FILENAME        Output file name.
        -s SIZE            In raw mode: the exact size of each input block, except the last one.
                           In tar mode: the minimum size of an input block, in bytes.
                                        A block is composed by one or more whole files.
                                        A file is never truncated unless -S is used.
                                        If not specified one block will contain exactly one file, no matter the file size.
                                        Each block is compressed to a zstd frame but if the archive has a lot of small files
                                        having a file per block doesn't compress very well. With this you can set a trade off.
                           The greater is SIZE the smaller will be the archive at the expense of the seek speed.
                           SIZE may be followed by the following multiplicative suffixes:
                               k/K/KiB = 1024
                               M/MiB = 1024^2
                               G/GiB = 1024^3
                               kB/KB = 1000
                               MB = 1000^2
                               GB = 1000^3
        -S SIZE            In raw mode: it is ignored.
                           In tar mode: the maximum size of an input block, in bytes.
                           Unlike -s this option may split big files in smaller chuncks.
                           Remember that each block is compressed independently and a small value here will result in a bigger archive.
                           -S can be used together with -s but MUST be greater or equal to it's value.
                           If -S and -s are equal the input block will be of exactly that size, if there is enough input data.
                           Like -s SIZE may be followed by one of the multiplicative suffixes described above.
        -T [1..N]          Number of thread to spawn. It improves compression speed but cost more memory. Default is single thread.
                           It requires libzstd >= 1.5.0 or an older version compiler with ZSTD_MULTITHREAD.
                           If `-s` or `-S` are too small it is possible that a lower number of threads will be used.
        -r                 Raw mode or non-tar mode. Treat tar archives as regular files, without any special handling.
        -j                 Do not generate a seek table.
        -v                 Verbose. List the elements in the tar archive and their size.
        -f                 Overwrite output without prompting.
        -h                 Print this help.
        -V                 Print the version.

```

# License

See LICENSE

# Release

Download the latest stable source code or .deb from the [release page](https://github.com/martinellimarco/t2sz/releases/latest). This is the raccomanded version.

# Snap

For your convenience you can install the latest release from the [snap store](https://snapcraft.io/t2sz) but beware that it is distributed in strict mode and it can access only your home directory by default.

You can add access to removable devices such as those stored in `/media` with `sudo snap connect t2sz:removable-media`.

If you want to give it access to every file you can install it with `--devmode`.

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/t2sz)
