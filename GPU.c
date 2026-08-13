//gcc -O3 -march=native GPU.c -lOpenCL
#define CL_TARGET_OPENCL_VERSION 120
#ifdef __APPLE__
#include <OpenCL/opencl.h>
#else
#include <CL/cl.h>
#endif
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
#define GROUPS_PER_CU 32u
#define CP_MAGIC UINT64_C(0x4e47505532353631) /* "NGPU2561" */
#define CP_VERSION 1u

typedef struct {
    uint64_t magic, next, best;
    uint32_t zeros, version;
} checkpoint_t;

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
    memcpy(out, "noah ostle", 10);
    for (int p = (int)l - 1; p >= 0; --p) {
        out[10 + p] = (char)(33 + x % 94);
        x /= 94;
    }
    out[10 + l] = 0;
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

static char *read_file(const char *path, size_t *size_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    char *s = (char *)malloc((size_t)n + 1);
    if (!s) { fclose(f); return NULL; }
    if (fread(s, 1, (size_t)n, f) != (size_t)n) { free(s); fclose(f); return NULL; }
    fclose(f);
    s[n] = 0;
    if (size_out) *size_out = (size_t)n;
    return s;
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

static void cl_die(cl_int e, const char *where) {
    if (e != CL_SUCCESS) {
        fprintf(stderr, "%s failed (OpenCL error %d)\n", where, e);
        exit(1);
    }
}

int main(int argc, char **argv) {
    const char *cp_path = "vanitysha_gpu.chk";
    const char *kernel_path = "vanitysha_gpu.cl";
    uint64_t override_start = 0;
    int have_override = 0;
    unsigned device_index = 0;
    double target_ms = 500.0;

    for (int a = 1; a < argc; ++a) {
        if (!strcmp(argv[a], "-s") && a + 1 < argc) { override_start = parse_u64(argv[++a], "start index"); have_override = 1; }
        else if (!strcmp(argv[a], "-c") && a + 1 < argc) cp_path = argv[++a];
        else if (!strcmp(argv[a], "-k") && a + 1 < argc) kernel_path = argv[++a];
        else if (!strcmp(argv[a], "-d") && a + 1 < argc) device_index = (unsigned)parse_u64(argv[++a], "device index");
        else if (!strcmp(argv[a], "-m") && a + 1 < argc) target_ms = strtod(argv[++a], NULL);
        else {
            fprintf(stderr, "usage: %s [-s start_index] [-c checkpoint] [-d gpu_index] [-m target_kernel_ms] [-k kernel.cl]\n", argv[0]);
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

    cl_int e;
    cl_uint np = 0;
    cl_die(clGetPlatformIDs(0, NULL, &np), "clGetPlatformIDs");
    cl_platform_id *plats = (cl_platform_id *)malloc(np * sizeof *plats);
    cl_die(clGetPlatformIDs(np, plats, NULL), "clGetPlatformIDs");

    cl_device_id devices[64];
    unsigned ndev = 0;
    for (cl_uint p = 0; p < np && ndev < 64; ++p) {
        cl_uint n = 0;
        if (clGetDeviceIDs(plats[p], CL_DEVICE_TYPE_GPU, 0, NULL, &n) != CL_SUCCESS) continue;
        cl_device_id *d = (cl_device_id *)malloc(n * sizeof *d);
        if (!d) return 1;
        if (clGetDeviceIDs(plats[p], CL_DEVICE_TYPE_GPU, n, d, NULL) == CL_SUCCESS) {
            for (cl_uint j = 0; j < n && ndev < 64; ++j) devices[ndev++] = d[j];
        }
        free(d);
    }
    free(plats);
    if (!ndev) { fprintf(stderr, "no OpenCL GPU found\n"); return 1; }
    if (device_index >= ndev) { fprintf(stderr, "GPU index %u out of range (found %u)\n", device_index, ndev); return 1; }
    cl_device_id dev = devices[device_index];

    char name[256] = {0}, vendor[256] = {0};
    cl_uint cu = 0;
    size_t maxwg = 0;
    clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_VENDOR, sizeof vendor, vendor, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof cu, &cu, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_MAX_WORK_GROUP_SIZE, sizeof maxwg, &maxwg, NULL);
    if (maxwg < WG) { fprintf(stderr, "GPU only supports work-groups of %zu; kernel requires %u\n", maxwg, WG); return 1; }
    printf("GPU %u/%u: %s (%s), %u compute units\n", device_index, ndev - 1, name, vendor, cu);

    cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &e); cl_die(e, "clCreateContext");
    cl_command_queue q = clCreateCommandQueue(ctx, dev, CL_QUEUE_PROFILING_ENABLE, &e); cl_die(e, "clCreateCommandQueue");

    size_t src_n = 0;
    char *src = read_file(kernel_path, &src_n);
    if (!src) { fprintf(stderr, "cannot read %s\n", kernel_path); return 1; }
    const char *srcs[] = { src };
    cl_program prog = clCreateProgramWithSource(ctx, 1, srcs, &src_n, &e); cl_die(e, "clCreateProgramWithSource");
    e = clBuildProgram(prog, 1, &dev, "-cl-std=CL1.2", NULL, NULL);
    if (e != CL_SUCCESS) {
        size_t n = 0; clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &n);
        char *log = (char *)malloc(n + 1);
        if (log) { clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, n, log, NULL); log[n] = 0; fprintf(stderr, "%s\n", log); free(log); }
        cl_die(e, "clBuildProgram");
    }
    free(src);
    cl_kernel k = clCreateKernel(prog, "search", &e); cl_die(e, "clCreateKernel");

    const size_t groups = (size_t)(cu ? cu : 1u) * GROUPS_PER_CU;
    const size_t global = groups * WG;
    uint64_t *results = (uint64_t *)malloc(groups * 2 * sizeof(uint64_t));
    if (!results) return 1;
    cl_mem out = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, groups * 2 * sizeof(uint64_t), NULL, &e); cl_die(e, "clCreateBuffer");

    uint32_t iters = 64;
    int tuned = 0;
    time_t last_save = time(NULL), last_print = last_save;
    double window_seconds = 0.0;
    uint64_t window_hashes = 0;

    printf("start=%" PRIu64 " checkpoint=%s target-kernel=%.0f ms\n", cp.next, cp_path, target_ms);

    while (!interrupted) {
        uint32_t L;
        uint64_t off, remain;
        locate(cp.next, &L, &off, &remain);

        uint64_t wanted = (uint64_t)global * (uint64_t)iters;
        uint64_t count = wanted;
        if (L < 10 && count > remain) count = remain;
        if (UINT64_MAX - cp.next < count - 1) count = UINT64_MAX - cp.next + 1;
        if (!count) break;

        cl_ulong abs0 = (cl_ulong)cp.next, off0 = (cl_ulong)off, cnt = (cl_ulong)count;
        cl_uint l = (cl_uint)L, it = (cl_uint)iters;
        cl_die(clSetKernelArg(k, 0, sizeof abs0, &abs0), "clSetKernelArg");
        cl_die(clSetKernelArg(k, 1, sizeof off0, &off0), "clSetKernelArg");
        cl_die(clSetKernelArg(k, 2, sizeof l, &l), "clSetKernelArg");
        cl_die(clSetKernelArg(k, 3, sizeof cnt, &cnt), "clSetKernelArg");
        cl_die(clSetKernelArg(k, 4, sizeof it, &it), "clSetKernelArg");
        cl_die(clSetKernelArg(k, 5, sizeof out, &out), "clSetKernelArg");

        cl_event ev;
        const size_t local = WG;
        cl_die(clEnqueueNDRangeKernel(q, k, 1, NULL, &global, &local, 0, NULL, &ev), "clEnqueueNDRangeKernel");
        cl_die(clEnqueueReadBuffer(q, out, CL_TRUE, 0, groups * 2 * sizeof(uint64_t), results, 1, &ev, NULL), "clEnqueueReadBuffer");

        cl_ulong t0 = 0, t1 = 0;
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, sizeof t0, &t0, NULL);
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, sizeof t1, &t1, NULL);
        clReleaseEvent(ev);
        double secs = t1 > t0 ? (double)(t1 - t0) * 1e-9 : 0.0;

        uint32_t batch_z = 0;
        uint64_t batch_i = UINT64_MAX;
        for (size_t g = 0; g < groups; ++g) {
            uint32_t z = (uint32_t)results[2 * g];
            uint64_t i = results[2 * g + 1];
            if (i != UINT64_MAX && (z > batch_z || (z == batch_z && i < batch_i))) { batch_z = z; batch_i = i; }
        }

        int improved = 0;
        if (batch_i != UINT64_MAX && (cp.best == UINT64_MAX || batch_z > cp.zeros)) {
            cp.zeros = batch_z;
            cp.best = batch_i;
            improved = 1;
        }

        int at_end = (count - 1 == UINT64_MAX - cp.next);
        if (!at_end) cp.next += count;

        window_hashes += count;
        window_seconds += secs;
        time_t now = time(NULL);

        if (improved) {
            char b[32]; candidate(cp.best, b);
            printf("\nNEW BEST: %u leading hex zero%s | index=%" PRIu64 " | %s\n", cp.zeros, cp.zeros == 1 ? "" : "s", cp.best, b);
        }

        if (!tuned && count == wanted && secs > 0.005) {
            double scale = (target_ms / 1000.0) / secs;
            uint64_t ni = (uint64_t)((double)iters * scale + 0.5);
            if (ni < 16) ni = 16;
            if (ni > 4096) ni = 4096;
            ni = (ni + 7) & ~UINT64_C(7);
            iters = (uint32_t)ni;
            tuned = 1;
            printf("autotune: %.1f MH/s, %u hashes/work-item (~%.0f ms kernels)\n", count / secs / 1e6, iters, target_ms);
        }

        if (now != (time_t)-1 && now - last_print >= 2) {
            double mh = window_seconds > 0 ? (double)window_hashes / window_seconds / 1e6 : 0;
            printf("\rnext=%" PRIu64 "  best=%u  %.1f MH/s      ", cp.next, cp.zeros, mh);
            fflush(stdout);
            window_hashes = 0; window_seconds = 0; last_print = now;
        }

        if (improved || (now != (time_t)-1 && now - last_save >= 10)) {
            if (!save_checkpoint(cp_path, &cp)) fprintf(stderr, "\nwarning: could not save checkpoint %s\n", cp_path);
            last_save = now;
        }

        if (at_end) break;
    }

    if (!save_checkpoint(cp_path, &cp)) fprintf(stderr, "\nwarning: could not save final checkpoint %s\n", cp_path);
    else printf("\nsaved checkpoint: next=%" PRIu64 " best=%u\n", cp.next, cp.zeros);

    clReleaseMemObject(out);
    clReleaseKernel(k);
    clReleaseProgram(prog);
    clReleaseCommandQueue(q);
    clReleaseContext(ctx);
    free(results);
    return 0;
}
