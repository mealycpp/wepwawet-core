####
# WEPWAWET-CORE HwAccelMgr: F' component + C FPGA driver + PQClean ML-DSA-44 aarch64 NEON (CPU baseline)
# Crypto/driver sources are compiled -O3 regardless of the F' build type so the CPU baseline is not handicapped.
####
enable_language(ASM)
set(PQN "${CMAKE_CURRENT_LIST_DIR}/pqclean_neon")
set(WCORE_C_SRCS
    "${CMAKE_CURRENT_LIST_DIR}/wcore_fpga.c"
    "${PQN}/ntt.c" "${PQN}/packing.c" "${PQN}/poly.c" "${PQN}/polyvec.c" "${PQN}/reduce.c"
    "${PQN}/rounding.c" "${PQN}/sign.c" "${PQN}/symmetric-shake.c" "${PQN}/fips202.c" "${PQN}/randombytes.c"
    "${PQN}/keccak2x/fips202x2.c")
set(WCORE_S_SRCS "${PQN}/__asm_NTT.S" "${PQN}/__asm_iNTT.S" "${PQN}/__asm_poly.S" "${PQN}/keccak2x/feat.S")
set_source_files_properties(${WCORE_C_SRCS} ${WCORE_S_SRCS} PROPERTIES COMPILE_OPTIONS "-O3")
register_fprime_library(
    AUTOCODER_INPUTS
        "${CMAKE_CURRENT_LIST_DIR}/HwAccelMgr.fpp"
    SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/HwAccelMgr.cpp"
        ${WCORE_C_SRCS}
        ${WCORE_S_SRCS}
)
