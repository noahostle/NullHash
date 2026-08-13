// CUDA vanity SHA-256 search: hashes inputs of the form "noah ostle {<printable suffix>}"
// RTX 4060 / Ada compile example:
//   nvcc -O3 -arch=sm_89 GPU_braced.cu -o GPU

#include <cuda_runtime.h>
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#define WG 256u
#define BLOCKS_PER_SM 32u
#define CP_MAGIC UINT64_C(0x4e47505542524331) /* "NGPUBRC1" -- braced-input build */
#define CP_VERSION 1u

typedef struct {
    uint64_t magic, next, best;
    uint32_t zeros, version;
} checkpoint_t;

typedef struct {
    unsigned long long z, i;
} gpu_result_t;

static volatile sig_atomic_t interrupted;
static void on_signal(int sig) { (void)sig; interrupted = 1; }

static const uint64_t start_of_len[10] = {
    UINT64_C(0),
    UINT64_C(94),
    UINT64_C(8930),
    UINT64_C(839514),
    UINT64_C(78914410),
    UINT64_C(7417954634),
    UINT64_C(697287735690),
    UINT64_C(65545047154954),
    UINT64_C(6161234432565770),
    UINT64_C(579156036661182474)
};
static const uint64_t count_of_len[9] = {
    UINT64_C(94),
    UINT64_C(8836),
    UINT64_C(830584),
    UINT64_C(78074896),
    UINT64_C(7339040224),
    UINT64_C(689869781056),
    UINT64_C(64847759419264),
    UINT64_C(6095689385410816),
    UINT64_C(572994802228616704)
};

static void locate(uint64_t i, uint32_t *len, uint64_t *off, uint64_t *remaining) {
    unsigned l = 0;
    while (l < 9 && i >= start_of_len[l + 1]) ++l;
    *len = l + 1;
    *off = i - start_of_len[l];
    *remaining = l < 9 ? count_of_len[l] - *off : UINT64_MAX;
}

static void candidate(uint64_t i, char out[32]) {
    uint32_t l; uint64_t x, rem;
    locate(i, &l, &x, &rem);
    memcpy(out, "noah ostle {", 12);
    for (int p = (int)l - 1; p >= 0; --p) {
        out[12 + p] = (char)(33 + x % 94);
        x /= 94;
    }
    out[12 + l] = '}';
    out[13 + l] = 0;
}

static int load_checkpoint(const char *path, checkpoint_t *c) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    checkpoint_t t;
    int ok = fread(&t, sizeof t, 1, f) == 1 &&
             t.magic == CP_MAGIC && t.version == CP_VERSION && t.zeros <= 64;
    fclose(f);
    if (ok) *c = t;
    return ok;
}

static int save_checkpoint(const char *path, const checkpoint_t *c) {
    char tmp[1024];
    if (snprintf(tmp, sizeof tmp, "%s.tmp", path) >= (int)sizeof tmp) return 0;
    FILE *f = fopen(tmp, "wb");
    if (!f) return 0;
    int ok = fwrite(c, sizeof *c, 1, f) == 1 && fflush(f) == 0;
    if (fclose(f) != 0) ok = 0;
    if (!ok) { remove(tmp); return 0; }
#ifdef _WIN32
    if (!MoveFileExA(tmp, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) { remove(tmp); return 0; }
#else
    if (rename(tmp, path) != 0) { remove(tmp); return 0; }
#endif
    return 1;
}

static uint64_t parse_u64(const char *s, const char *what) {
    char *e = NULL;
    errno = 0;
    unsigned long long v = strtoull(s, &e, 0);
    if (errno || !s[0] || (e && *e)) {
        fprintf(stderr, "invalid %s: %s\n", what, s);
        exit(2);
    }
    return (uint64_t)v;
}

static void cuda_die(cudaError_t e, const char *where) {
    if (e != cudaSuccess) {
        fprintf(stderr, "%s failed: %s\n", where, cudaGetErrorString(e));
        exit(1);
    }
}

// SHA-256 helpers. With constant rotate amounts nvcc emits native funnel-shift instructions on Ada.
#define ROR(x,n) (((x) >> (n)) | ((x) << (32u - (n))))
#define CH(x,y,z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define B0(x) (ROR((x),2)^ROR((x),13)^ROR((x),22))
#define B1(x) (ROR((x),6)^ROR((x),11)^ROR((x),25))
#define S0(x) (ROR((x),7)^ROR((x),18)^((x)>>3))
#define S1(x) (ROR((x),17)^ROR((x),19)^((x)>>10))
#define X(i) (w[(i)] += S0(w[((i)+1)&15]) + w[((i)+9)&15] + S1(w[((i)+14)&15]))
#define R(x,k) do { \
    uint32_t T1 = h + B1(e) + CH(e,f,g) + (uint32_t)(k) + (uint32_t)(x); \
    uint32_t T2 = B0(a) + MAJ(a,b,c); \
    h=g; g=f; f=e; e=d+T1; d=c; c=b; b=a; a=T1+T2; \
} while (0)

__device__ __forceinline__ uint32_t hz(uint32_t a, uint32_t b, uint32_t c, uint32_t d,
                                       uint32_t e, uint32_t f, uint32_t g, uint32_t h) {
    uint32_t q, z = 0;
    q = (uint32_t)__clz(a + 0x6a09e667U) >> 2; z += q; if (q < 8) return z;
    q = (uint32_t)__clz(b + 0xbb67ae85U) >> 2; z += q; if (q < 8) return z;
    q = (uint32_t)__clz(c + 0x3c6ef372U) >> 2; z += q; if (q < 8) return z;
    q = (uint32_t)__clz(d + 0xa54ff53aU) >> 2; z += q; if (q < 8) return z;
    q = (uint32_t)__clz(e + 0x510e527fU) >> 2; z += q; if (q < 8) return z;
    q = (uint32_t)__clz(f + 0x9b05688cU) >> 2; z += q; if (q < 8) return z;
    q = (uint32_t)__clz(g + 0x1f83d9abU) >> 2; z += q; if (q < 8) return z;
    q = (uint32_t)__clz(h + 0x5be0cd19U) >> 2; return z + q;
}

__device__ __forceinline__ void take_better(uint32_t oz, unsigned long long oi,
                                            uint32_t *z, unsigned long long *i) {
    if (oz > *z || (oz == *z && oi < *i)) {
        *z = oz;
        *i = oi;
    }
}

__global__ __launch_bounds__(WG)
void search_kernel(unsigned long long abs0, unsigned long long off0, uint32_t L,
                   unsigned long long count, uint32_t iters, gpu_result_t *out) {
    const uint32_t tid = threadIdx.x;
    const unsigned long long gid = (unsigned long long)blockIdx.x * blockDim.x + tid;
    const unsigned long long rel = gid * (unsigned long long)iters;

    uint32_t bz = 0;
    unsigned long long bi = ~0ULL;

    if (rel < count) {
        uint32_t m[6] = {0x6e6f6168U, 0x206f7374U, 0x6c65207bU, 0, 0, 0}; /* "noah ostle {" */
        unsigned long long x = off0 + rel;

        for (int p = (int)L - 1; p >= 0; --p) {
            const uint32_t pos = 12U + (uint32_t)p;
            const uint32_t sh = 24U - 8U * (pos & 3U);
            const uint32_t ch = 33U + (uint32_t)(x % 94ULL);
            x /= 94ULL;
            m[pos >> 2] |= ch << sh;
        }

        {
            const uint32_t pos = 12U + L;
            const uint32_t sh = 24U - 8U * (pos & 3U);
            m[pos >> 2] |= 0x7dU << sh; /* '}' */
        }
        {
            const uint32_t pos = 13U + L;
            const uint32_t sh = 24U - 8U * (pos & 3U);
            m[pos >> 2] |= 0x80U << sh;
        }

        const uint32_t bitlen = (13U + L) * 8U;
        const unsigned long long left = count - rel;
        const uint32_t n = (uint32_t)(left < (unsigned long long)iters ? left : (unsigned long long)iters);

        for (uint32_t j = 0; j < n; ++j) {
            uint32_t w[16];
            w[0]=m[0]; w[1]=m[1]; w[2]=m[2]; w[3]=m[3]; w[4]=m[4]; w[5]=m[5];
            w[6]=0; w[7]=0; w[8]=0; w[9]=0; w[10]=0; w[11]=0; w[12]=0; w[13]=0; w[14]=0; w[15]=bitlen;

            uint32_t a=0x6a09e667U,b=0xbb67ae85U,c=0x3c6ef372U,d=0xa54ff53aU;
            uint32_t e=0x510e527fU,f=0x9b05688cU,g=0x1f83d9abU,h=0x5be0cd19U;

            R(w[0], 0x428a2f98U); R(w[1], 0x71374491U); R(w[2], 0xb5c0fbcfU); R(w[3], 0xe9b5dba5U);
            R(w[4], 0x3956c25bU); R(w[5], 0x59f111f1U); R(w[6], 0x923f82a4U); R(w[7], 0xab1c5ed5U);
            R(w[8], 0xd807aa98U); R(w[9], 0x12835b01U); R(w[10],0x243185beU); R(w[11],0x550c7dc3U);
            R(w[12],0x72be5d74U); R(w[13],0x80deb1feU); R(w[14],0x9bdc06a7U); R(w[15],0xc19bf174U);
            R(X(0), 0xe49b69c1U); R(X(1), 0xefbe4786U); R(X(2), 0x0fc19dc6U); R(X(3), 0x240ca1ccU);
            R(X(4), 0x2de92c6fU); R(X(5), 0x4a7484aaU); R(X(6), 0x5cb0a9dcU); R(X(7), 0x76f988daU);
            R(X(8), 0x983e5152U); R(X(9), 0xa831c66dU); R(X(10),0xb00327c8U); R(X(11),0xbf597fc7U);
            R(X(12),0xc6e00bf3U); R(X(13),0xd5a79147U); R(X(14),0x06ca6351U); R(X(15),0x14292967U);
            R(X(0), 0x27b70a85U); R(X(1), 0x2e1b2138U); R(X(2), 0x4d2c6dfcU); R(X(3), 0x53380d13U);
            R(X(4), 0x650a7354U); R(X(5), 0x766a0abbU); R(X(6), 0x81c2c92eU); R(X(7), 0x92722c85U);
            R(X(8), 0xa2bfe8a1U); R(X(9), 0xa81a664bU); R(X(10),0xc24b8b70U); R(X(11),0xc76c51a3U);
            R(X(12),0xd192e819U); R(X(13),0xd6990624U); R(X(14),0xf40e3585U); R(X(15),0x106aa070U);
            R(X(0), 0x19a4c116U); R(X(1), 0x1e376c08U); R(X(2), 0x2748774cU); R(X(3), 0x34b0bcb5U);
            R(X(4), 0x391c0cb3U); R(X(5), 0x4ed8aa4aU); R(X(6), 0x5b9cca4fU); R(X(7), 0x682e6ff3U);
            R(X(8), 0x748f82eeU); R(X(9), 0x78a5636fU); R(X(10),0x84c87814U); R(X(11),0x8cc70208U);
            R(X(12),0x90befffaU); R(X(13),0xa4506cebU); R(X(14),0xbef9a3f7U); R(X(15),0xc67178f2U);

            const uint32_t z = hz(a,b,c,d,e,f,g,h);
            const unsigned long long idx = abs0 + rel + (unsigned long long)j;
            if (z > bz || (z == bz && idx < bi)) { bz = z; bi = idx; }

            if (j + 1U < n) {
                for (int p = (int)L - 1; p >= 0; --p) {
                    const uint32_t pos = 12U + (uint32_t)p;
                    const uint32_t wi = pos >> 2;
                    const uint32_t sh = 24U - 8U * (pos & 3U);
                    const uint32_t mask = 0xffU << sh;
                    const uint32_t v = (m[wi] >> sh) & 0xffU;
                    if (v < 126U) {
                        m[wi] = (m[wi] & ~mask) | ((v + 1U) << sh);
                        break;
                    }
                    m[wi] = (m[wi] & ~mask) | (33U << sh);
                }
            }
        }
    }

    // Warp-shuffle reduction: same result as the OpenCL local-memory tree,
    // but only one block-wide synchronization is required.
    const unsigned mask = 0xffffffffU;
    for (int delta = 16; delta > 0; delta >>= 1) {
        const uint32_t oz = __shfl_down_sync(mask, bz, delta);
        const unsigned long long oi = __shfl_down_sync(mask, bi, delta);
        if ((tid & 31U) + (uint32_t)delta < 32U) take_better(oz, oi, &bz, &bi);
    }

    __shared__ uint32_t warp_z[8];
    __shared__ unsigned long long warp_i[8];
    const uint32_t lane = tid & 31U;
    const uint32_t warp = tid >> 5;
    if (lane == 0) { warp_z[warp] = bz; warp_i[warp] = bi; }
    __syncthreads();

    if (warp == 0) {
        bz = lane < 8U ? warp_z[lane] : 0U;
        bi = lane < 8U ? warp_i[lane] : ~0ULL;
        for (int delta = 16; delta > 0; delta >>= 1) {
            const uint32_t oz = __shfl_down_sync(mask, bz, delta);
            const unsigned long long oi = __shfl_down_sync(mask, bi, delta);
            if (lane + (uint32_t)delta < 32U) take_better(oz, oi, &bz, &bi);
        }
        if (lane == 0) {
            out[blockIdx.x].z = (unsigned long long)bz;
            out[blockIdx.x].i = bi;
        }
    }
}

int main(int argc, char **argv) {
    const char *cp_path = "vanitysha_braced.chk";
    uint64_t override_start = 0;
    int have_override = 0;
    unsigned device_index = 0;
    double target_ms = 500.0;

    for (int a = 1; a < argc; ++a) {
        if (!strcmp(argv[a], "-s") && a + 1 < argc) { override_start = parse_u64(argv[++a], "start index"); have_override = 1; }
        else if (!strcmp(argv[a], "-c") && a + 1 < argc) cp_path = argv[++a];
        else if (!strcmp(argv[a], "-d") && a + 1 < argc) device_index = (unsigned)parse_u64(argv[++a], "device index");
        else if (!strcmp(argv[a], "-m") && a + 1 < argc) target_ms = strtod(argv[++a], NULL);
        else if (!strcmp(argv[a], "-k") && a + 1 < argc) { ++a; /* accepted for old scripts; CUDA kernel is compiled in */ }
        else {
            fprintf(stderr, "usage: %s [-s start_index] [-c checkpoint] [-d gpu_index] [-m target_kernel_ms]\n", argv[0]);
            return 2;
        }
    }
    if (!(target_ms >= 20.0 && target_ms <= 1500.0)) {
        fprintf(stderr, "-m must be between 20 and 1500 ms\n");
        return 2;
    }

    signal(SIGINT, on_signal);
#ifdef SIGTERM
    signal(SIGTERM, on_signal);
#endif

    checkpoint_t cp = { CP_MAGIC, 0, UINT64_MAX, 0, CP_VERSION };
    if (load_checkpoint(cp_path, &cp)) {
        char b[32];
        printf("checkpoint: next=%" PRIu64, cp.next);
        if (cp.best != UINT64_MAX) { candidate(cp.best, b); printf(" best=%u [%s]", cp.zeros, b); }
        putchar('\n');
    }
    if (have_override) cp.next = override_start;

    int ndev = 0;
    cuda_die(cudaGetDeviceCount(&ndev), "cudaGetDeviceCount");
    if (ndev <= 0) { fprintf(stderr, "no CUDA GPU found\n"); return 1; }
    if (device_index >= (unsigned)ndev) {
        fprintf(stderr, "GPU index %u out of range (found %d)\n", device_index, ndev);
        return 1;
    }
    cuda_die(cudaSetDevice((int)device_index), "cudaSetDevice");

    cudaDeviceProp prop;
    cuda_die(cudaGetDeviceProperties(&prop, (int)device_index), "cudaGetDeviceProperties");
    if (prop.maxThreadsPerBlock < (int)WG) {
        fprintf(stderr, "GPU only supports blocks of %d threads; kernel requires %u\n", prop.maxThreadsPerBlock, WG);
        return 1;
    }
    printf("GPU %u/%d: %s, %d SMs, compute capability %d.%d\n",
           device_index, ndev - 1, prop.name, prop.multiProcessorCount, prop.major, prop.minor);

    const size_t blocks = (size_t)(prop.multiProcessorCount ? prop.multiProcessorCount : 1) * BLOCKS_PER_SM;
    const size_t global = blocks * WG;

    gpu_result_t *results = NULL;
    gpu_result_t *d_out = NULL;
    cuda_die(cudaMallocHost((void **)&results, blocks * sizeof(*results)), "cudaMallocHost(results)");
    cuda_die(cudaMalloc((void **)&d_out, blocks * sizeof(*d_out)), "cudaMalloc(d_out)");

    cudaEvent_t ev0, ev1;
    cuda_die(cudaEventCreate(&ev0), "cudaEventCreate(start)");
    cuda_die(cudaEventCreate(&ev1), "cudaEventCreate(stop)");

    uint32_t iters = 64;
    int tuned = 0;
    time_t last_save = time(NULL), last_print = last_save;
    double window_seconds = 0.0;
    uint64_t window_hashes = 0;

    printf("start=%" PRIu64 " checkpoint=%s target-kernel=%.0f ms blocks=%zu threads/block=%u\n",
           cp.next, cp_path, target_ms, blocks, WG);

    while (!interrupted) {
        uint32_t L;
        uint64_t off, remain;
        locate(cp.next, &L, &off, &remain);

        uint64_t wanted = (uint64_t)global * (uint64_t)iters;
        uint64_t count = wanted;
        if (L < 10 && count > remain) count = remain;
        if (UINT64_MAX - cp.next < count - 1) count = UINT64_MAX - cp.next + 1;
        if (!count) break;

        cuda_die(cudaEventRecord(ev0), "cudaEventRecord(start)");
        search_kernel<<<(unsigned)blocks, WG>>>((unsigned long long)cp.next,
                                                (unsigned long long)off,
                                                L,
                                                (unsigned long long)count,
                                                iters,
                                                d_out);
        cuda_die(cudaGetLastError(), "search_kernel launch");
        cuda_die(cudaEventRecord(ev1), "cudaEventRecord(stop)");
        cuda_die(cudaEventSynchronize(ev1), "cudaEventSynchronize(stop)");

        float elapsed_ms = 0.0f;
        cuda_die(cudaEventElapsedTime(&elapsed_ms, ev0, ev1), "cudaEventElapsedTime");
        const double secs = (double)elapsed_ms * 1e-3;

        cuda_die(cudaMemcpy(results, d_out, blocks * sizeof(*results), cudaMemcpyDeviceToHost), "cudaMemcpy(results)");

        uint32_t batch_z = 0;
        uint64_t batch_i = UINT64_MAX;
        for (size_t g = 0; g < blocks; ++g) {
            const uint32_t z = (uint32_t)results[g].z;
            const uint64_t i = (uint64_t)results[g].i;
            if (i != UINT64_MAX && (z > batch_z || (z == batch_z && i < batch_i))) {
                batch_z = z;
                batch_i = i;
            }
        }

        int improved = 0;
        if (batch_i != UINT64_MAX && (cp.best == UINT64_MAX || batch_z > cp.zeros)) {
            cp.zeros = batch_z;
            cp.best = batch_i;
            improved = 1;
        }

        const int at_end = (count - 1 == UINT64_MAX - cp.next);
        if (!at_end) cp.next += count;

        window_hashes += count;
        window_seconds += secs;
        time_t now = time(NULL);

        if (improved) {
            char b[32]; candidate(cp.best, b);
            printf("\nNEW BEST: %u leading hex zero%s | index=%" PRIu64 " | %s\n",
                   cp.zeros, cp.zeros == 1 ? "" : "s", cp.best, b);
        }

        if (!tuned && count == wanted && secs > 0.005) {
            const double scale = (target_ms / 1000.0) / secs;
            uint64_t ni = (uint64_t)((double)iters * scale + 0.5);
            if (ni < 16) ni = 16;
            if (ni > 4096) ni = 4096;
            ni = (ni + 7) & ~UINT64_C(7);
            iters = (uint32_t)ni;
            tuned = 1;
            printf("autotune: %.1f MH/s, %u hashes/thread (~%.0f ms kernels)\n",
                   count / secs / 1e6, iters, target_ms);
        }

        if (now != (time_t)-1 && now - last_print >= 1) {
            const double mh = window_seconds > 0 ? (double)window_hashes / window_seconds / 1e6 : 0;
            printf("\rnext=%" PRIu64 "  best=%u  %.1f MH/s      ", cp.next, cp.zeros, mh);
            fflush(stdout);
            window_hashes = 0;
            window_seconds = 0;
            last_print = now;
        }

        if (improved || (now != (time_t)-1 && now - last_save >= 10)) {
            if (!save_checkpoint(cp_path, &cp))
                fprintf(stderr, "\nwarning: could not save checkpoint %s\n", cp_path);
            last_save = now;
        }

        if (at_end) break;
    }

    if (!save_checkpoint(cp_path, &cp))
        fprintf(stderr, "\nwarning: could not save final checkpoint %s\n", cp_path);
    else
        printf("\nsaved checkpoint: next=%" PRIu64 " best=%u\n", cp.next, cp.zeros);

    cudaEventDestroy(ev1);
    cudaEventDestroy(ev0);
    cudaFree(d_out);
    cudaFreeHost(results);
    return 0;
}
