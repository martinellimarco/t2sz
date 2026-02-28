cmake_minimum_required(VERSION 3.16)

# ── Apple / Homebrew LLVM workarounds ─────────────────────────────────────────
#
# 1. libc++ mismatch: Homebrew LLVM's libFuzzer runtime is linked against its
#    own libc++, which contains symbols (e.g. std::__1::__hash_memory) absent
#    from Apple's system libc++. We detect the compiler's lib/c++ directory and
#    add it to the link path so the correct library is found at link + run time.
#
# 2. UBSAN object-file incompatibility: The full -fsanitize=undefined generates
#    relocation entries that Apple's system linker (ld) cannot parse ("invalid
#    r_symbolnum") for large translation units. The vptr and function checks
#    (C++-only, irrelevant for this pure-C project) are the culprits, so we
#    exclude them with -fno-sanitize=vptr,function.
if(APPLE)
    get_filename_component(_llvm_bindir "${CMAKE_C_COMPILER}" DIRECTORY)
    get_filename_component(_llvm_root   "${_llvm_bindir}" DIRECTORY)
    set(_llvm_libcxx "${_llvm_root}/lib/c++")
    if(EXISTS "${_llvm_libcxx}")
        set(FUZZ_EXTRA_LINK_FLAGS
            -L${_llvm_libcxx}
            "-Wl,-rpath,${_llvm_libcxx}"
        )
    endif()
    set(FUZZ_SANITIZE_FLAGS -fsanitize=fuzzer,address,undefined -fno-sanitize=vptr,function)
else()
    set(FUZZ_SANITIZE_FLAGS -fsanitize=fuzzer,address,undefined)
endif()

# ── Helper: register a libFuzzer harness ─────────────────────────────────────
# Each harness #includes ../src/t2sz.c directly (with -DT2SZ_NO_MAIN) so that
# all static functions are accessible without splitting the monolithic source.
function(add_fuzz_target name)
    add_executable(${name} ${name}.c)
    target_compile_options(${name} PRIVATE
        ${FUZZ_SANITIZE_FLAGS}
        -fno-omit-frame-pointer -g -O1
        -DT2SZ_NO_MAIN
    )
    target_link_options(${name} PRIVATE
        ${FUZZ_SANITIZE_FLAGS}
        ${FUZZ_EXTRA_LINK_FLAGS}
    )
    target_include_directories(${name} PRIVATE ${ZSTD_INC})
    target_link_libraries(${name} ${ZSTD_LIB} m)
endfunction()

# ── Fuzz targets ─────────────────────────────────────────────────────────────
add_fuzz_target(fuzz_tar_mmap)
add_fuzz_target(fuzz_tar_stdin)
add_fuzz_target(fuzz_cli)

# ── Seed corpus generation ───────────────────────────────────────────────────
set(CORPUS_MMAP  ${CMAKE_CURRENT_BINARY_DIR}/corpus_mmap)
set(CORPUS_STDIN ${CMAKE_CURRENT_BINARY_DIR}/corpus_stdin)
set(CORPUS_CLI   ${CMAKE_CURRENT_BINARY_DIR}/corpus_cli)

add_custom_target(fuzz_corpus
    COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/gen_corpus.sh
            ${CORPUS_MMAP} ${CORPUS_STDIN} ${CORPUS_CLI}
    COMMENT "Generating fuzz seed corpus in ${CMAKE_CURRENT_BINARY_DIR}"
)
