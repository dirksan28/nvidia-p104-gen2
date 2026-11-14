/*
 * bwtest.cu - measure the host <-> GPU PCIe bandwidth of the unlocked link.
 *
 * This is how you verify that the patch delivers *usable* Gen2 bandwidth and
 * not just a 5 GT/s line in lspci. It copies a pinned host buffer to the
 * device and back with cudaMemcpyAsync and reports the achieved rate for each
 * direction, i.e. it measures the link, not GPU compute or VRAM bandwidth.
 *
 * Build:
 *   nvcc -O2 -arch=sm_61 -o bwtest bwtest.cu     (GP104 = sm_61, or -arch=native)
 *
 * Run:
 *   ./bwtest [MiB] [iterations]                  (defaults: 256 MiB, 8)
 *
 * Reference result on a P104-100 with this patch (Gen2 x4, link verified at
 * 5.0 GT/s throughout):
 *
 *   H2D:   2048 MiB in 1409.3 ms ->  1453 MiB/s (1.52 GB/s)
 *   D2H:   2048 MiB in 1332.6 ms ->  1537 MiB/s (1.61 GB/s)
 *
 * Gen2 x4 is 20 GT/s raw with 8b/10b encoding (~2.0 GB/s), so that is ~90 %
 * of the theoretical payload rate. On the stock Gen1 link the same test comes
 * out at roughly half that (~0.8 GB/s). An LLM inference workload moves only
 * tens of MiB/s, so it will not show these numbers - model load or an
 * explicit large memcpy will.
 *
 * Needs ~MiB of free VRAM and the same amount of pinned RAM; do not run it
 * while another job depends on the GPU.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>

#define CHECK(x)                                                              \
    do {                                                                      \
        cudaError_t e_ = (x);                                                 \
        if (e_ != cudaSuccess) {                                              \
            printf("CUDA error: %s (line %d)\n", cudaGetErrorString(e_),      \
                   __LINE__);                                                 \
            return 1;                                                         \
        }                                                                     \
    } while (0)

int main(int argc, char **argv)
{
    size_t mib = (argc > 1) ? strtoul(argv[1], NULL, 10) : 256;
    int iters = (argc > 2) ? atoi(argv[2]) : 8;
    size_t bytes = mib << 20;

    char *host = NULL;
    void *dev = NULL;

    CHECK(cudaSetDevice(0));
    CHECK(cudaHostAlloc((void **)&host, bytes, cudaHostAllocDefault));
    CHECK(cudaMalloc(&dev, bytes));
    memset(host, 1, bytes);

    cudaEvent_t start, stop;
    CHECK(cudaEventCreate(&start));
    CHECK(cudaEventCreate(&stop));

    CHECK(cudaMemcpy(dev, host, bytes, cudaMemcpyHostToDevice)); /* warm up */
    CHECK(cudaDeviceSynchronize());

    for (int dir = 0; dir < 2; dir++) {
        CHECK(cudaEventRecord(start));
        for (int i = 0; i < iters; i++) {
            if (dir == 0)
                CHECK(cudaMemcpyAsync(dev, host, bytes,
                                      cudaMemcpyHostToDevice));
            else
                CHECK(cudaMemcpyAsync(host, dev, bytes,
                                      cudaMemcpyDeviceToHost));
        }
        CHECK(cudaEventRecord(stop));
        CHECK(cudaEventSynchronize(stop));

        float ms = 0.0f;
        CHECK(cudaEventElapsedTime(&ms, start, stop));
        double moved_mib = (double)bytes * iters / 1048576.0;
        printf("%s: %6.0f MiB in %7.1f ms -> %7.0f MiB/s (%5.2f GB/s)\n",
               dir == 0 ? "H2D" : "D2H", moved_mib, ms,
               moved_mib * 1000.0 / ms,
               (double)bytes * iters / 1e9 * 1000.0 / ms);
    }

    cudaFreeHost(host);
    cudaFree(dev);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    return 0;
}
