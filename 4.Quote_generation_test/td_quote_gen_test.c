#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <math.h>
#include "tdx_attest.h"

#define devname         "/dev/tdx-attest"

#define HEX_DUMP_SIZE   16

static void print_hex_dump(const char *title, const char *prefix_str,
                const uint8_t *buf, int len)
{
        const uint8_t *ptr = buf;
        int i, rowsize = HEX_DUMP_SIZE;

        if (!len || !buf)
                return;

        fprintf(stdout, "\t\t%s", title);

        for (i = 0; i < len; i++) {
                if (!(i % rowsize))
                        fprintf(stdout, "\n%s%.8x:", prefix_str, i);
                if (ptr[i] <= 0x0f)
                        fprintf(stdout, " 0%x", ptr[i]);
                else
                        fprintf(stdout, " %x", ptr[i]);
        }

        fprintf(stdout, "\n");
}

static void gen_report_data(uint8_t *reportdata, unsigned int *seed)
{
        int i;

        for (i = 0; i < TDX_REPORT_DATA_SIZE; i++)
                reportdata[i] = (uint8_t)rand_r(seed);
}

static double timespec_diff_ms(const struct timespec *start, const struct timespec *end)
{
        double ms = (end->tv_sec - start->tv_sec) * 1000.0;
        ms += (end->tv_nsec - start->tv_nsec) / 1000000.0;
        return ms;
}

static double monotonic_now_ms(void)
{
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void usage(const char *prog)
{
        fprintf(stderr,
                        "Usage: %s [-d <duration_seconds>] [-n <threads>] [--serialized] [--percentiles] [--max-samples <N>] [--sweep <list>] [--csv <path>] [--both-modes] [--quiet]\n"
                        "\n"
                        "Runs tdx_att_get_quote in a loop for the given duration (default 1s) and prints a summary.\n"
                        "Use -n to run concurrent threads (default 1).\n"
                        "--serialized: force a global mutex around tdx_att_get_quote (for thread-safety/bottleneck comparison).\n"
                        "--percentiles: print P50/P95/P99 latency (success-only).\n"
                        "--max-samples: cap latency samples used for percentiles (default 200000, reservoir sampled).\n",
                        "\n"
                        "Sweep mode:\n"
                        "  --sweep <list>  Comma-separated thread list, e.g. --sweep 1,2,4,8\n"
                        "  --csv <path>    Write CSV to file (default: stdout)\n"
                        "  --both-modes    For each -n, run both concurrent and serialized\n"
                        "  --quiet         Suppress non-CSV output in sweep mode\n",
                        prog);
}

static pthread_mutex_t g_quote_mutex = PTHREAD_MUTEX_INITIALIZER;
static int g_serialized = 0;

static uint64_t rand_u64(unsigned int *seed)
{
        uint64_t hi = (uint64_t)(unsigned int)rand_r(seed);
        uint64_t lo = (uint64_t)(unsigned int)rand_r(seed);
        return (hi << 32) ^ lo;
}

static uint64_t rand_u64_bounded(unsigned int *seed, uint64_t bound)
{
        if (bound == 0)
                return 0;
        return rand_u64(seed) % bound;
}

static int cmp_double_asc(const void *a, const void *b)
{
        const double da = *(const double *)a;
        const double db = *(const double *)b;
        if (da < db)
                return -1;
        if (da > db)
                return 1;
        return 0;
}

static double percentile_nearest_rank(const double *sorted, size_t n, double p)
{
        if (n == 0)
                return 0.0;
        if (p <= 0.0)
                return sorted[0];
        if (p >= 1.0)
                return sorted[n - 1];

        const double rank = ceil(p * (double)n);
        size_t idx = (size_t)rank;
        if (idx == 0)
                idx = 1;
        if (idx > n)
                idx = n;
        return sorted[idx - 1];
}

typedef struct {
        pthread_barrier_t barrier;
        double start_ms;
        double end_ms;
} shared_ctx_t;

typedef struct {
        int thread_id;
        shared_ctx_t *shared;

        int total_count;
        int success_count;
        int failure_count;
        double min_elapsed_ms;
        double max_elapsed_ms;

        double *samples;
        int sample_cap;
        int sample_count;
        uint64_t success_seen;
} worker_stats_t;

typedef struct {
        int threads;
        int serialized;
        int duration_seconds;
        double actual_elapsed_s;

        int total_count;
        int success_count;
        int failure_count;

        double avg_total_per_s;
        double avg_success_per_s;

        double avg_total_per_s_per_thread;
        double avg_success_per_s_per_thread;

        int have_success_timing;
        double min_elapsed_ms;
        double max_elapsed_ms;

        int have_percentiles;
        double p50_ms;
        double p95_ms;
        double p99_ms;
        size_t samples_used;
} bench_result_t;

static void *quote_worker(void *arg)
{
        worker_stats_t *stats = (worker_stats_t *)arg;

        uint32_t quote_size = 0;
        tdx_report_data_t report_data = {{0}};
        tdx_uuid_t selected_att_key_id = {0};
        uint8_t *p_quote_buf = NULL;
        struct timespec start, end;

        stats->total_count = 0;
        stats->success_count = 0;
        stats->failure_count = 0;
        stats->min_elapsed_ms = 0.0;
        stats->max_elapsed_ms = 0.0;
        stats->sample_count = 0;
        stats->success_seen = 0;

        unsigned int seed = (unsigned int)time(NULL) ^ (unsigned int)(stats->thread_id * 2654435761u);

        pthread_barrier_wait(&stats->shared->barrier);

        while (monotonic_now_ms() < stats->shared->end_ms) {
                stats->total_count++;

                quote_size = 0;
                p_quote_buf = NULL;
                memset(&selected_att_key_id, 0, sizeof(selected_att_key_id));

                gen_report_data(report_data.d, &seed);

                if (g_serialized)
                        pthread_mutex_lock(&g_quote_mutex);

                clock_gettime(CLOCK_MONOTONIC, &start);
                if (TDX_ATTEST_SUCCESS != tdx_att_get_quote(&report_data, NULL, 0, &selected_att_key_id,
                        &p_quote_buf, &quote_size, 0)) {
                        clock_gettime(CLOCK_MONOTONIC, &end);
                        if (g_serialized)
                                pthread_mutex_unlock(&g_quote_mutex);
                        stats->failure_count++;
                        continue;
                }
                clock_gettime(CLOCK_MONOTONIC, &end);
                if (g_serialized)
                        pthread_mutex_unlock(&g_quote_mutex);

                const double elapsed_time = timespec_diff_ms(&start, &end);
                stats->success_count++;
                stats->success_seen++;

                if (stats->success_count == 1 || elapsed_time < stats->min_elapsed_ms)
                        stats->min_elapsed_ms = elapsed_time;
                if (stats->success_count == 1 || elapsed_time > stats->max_elapsed_ms)
                        stats->max_elapsed_ms = elapsed_time;

                if (stats->samples && stats->sample_cap > 0) {
                        if (stats->success_seen <= (uint64_t)stats->sample_cap) {
                                stats->samples[stats->sample_count++] = elapsed_time;
                        } else {
                                const uint64_t j = rand_u64_bounded(&seed, stats->success_seen);
                                if (j < (uint64_t)stats->sample_cap) {
                                        stats->samples[(int)j] = elapsed_time;
                                }
                        }
                }

                if (p_quote_buf) {
                        tdx_att_free_quote(p_quote_buf);
                        p_quote_buf = NULL;
                }
        }

        if (p_quote_buf) {
                tdx_att_free_quote(p_quote_buf);
                p_quote_buf = NULL;
        }

        return NULL;
}

static int run_once(int duration_seconds, int threads, int enable_percentiles, int max_samples, int quiet, bench_result_t *out)
{
        if (!out)
                return 1;

        if (!quiet) {
                printf("Start tdx_att_get_quote %s loop, duration: %d s, threads: %d\n",
                       g_serialized ? "serialized" : "concurrent", duration_seconds, threads);
        }

        pthread_t *tids = (pthread_t *)calloc((size_t)threads, sizeof(pthread_t));
        worker_stats_t *stats = (worker_stats_t *)calloc((size_t)threads, sizeof(worker_stats_t));
        if (!tids || !stats) {
                fprintf(stderr, "Out of memory\n");
                free(tids);
                free(stats);
                return 1;
        }

        shared_ctx_t shared;
        shared.start_ms = 0.0;
        shared.end_ms = 0.0;

        if (pthread_barrier_init(&shared.barrier, NULL, (unsigned)threads + 1) != 0) {
            fprintf(stderr, "Failed to init barrier\n");
            free(tids);
            free(stats);
            return 1;
        }

        int per_thread_cap = 0;
        if (enable_percentiles) {
                per_thread_cap = (threads > 0) ? (max_samples / threads) : 0;
                if (per_thread_cap < 1)
                        per_thread_cap = 1;
        }

        int started_threads = 0;
        for (int i = 0; i < threads; i++) {
                stats[i].thread_id = i;
                stats[i].shared = &shared;
                stats[i].samples = NULL;
                stats[i].sample_cap = 0;

                if (enable_percentiles) {
                        stats[i].sample_cap = per_thread_cap;
                        stats[i].samples = (double *)calloc((size_t)per_thread_cap, sizeof(double));
                        if (!stats[i].samples) {
                                fprintf(stderr, "Out of memory allocating samples\n");
                                break;
                        }
                }

                if (pthread_create(&tids[i], NULL, quote_worker, &stats[i]) != 0) {
                        fprintf(stderr, "Failed to create thread %d\n", i);
                        break;
                }
                started_threads++;
        }

        if (started_threads != threads) {
                fprintf(stderr, "Only started %d/%d threads\n", started_threads, threads);
                threads = started_threads;
        }

        shared.start_ms = monotonic_now_ms();
        shared.end_ms = shared.start_ms + (double)duration_seconds * 1000.0;
        pthread_barrier_wait(&shared.barrier);

        for (int i = 0; i < threads; i++)
                pthread_join(tids[i], NULL);

        const double wall_stop_ms = monotonic_now_ms();
        const double wall_elapsed_s = (wall_stop_ms - shared.start_ms) / 1000.0;
        /* Use actual wall time for accurate throughput calculation */
        const double elapsed_s = (wall_elapsed_s > 0.0) ? wall_elapsed_s : (double)duration_seconds;

        int total_count = 0;
        int success_count = 0;
        int failure_count = 0;
        double min_elapsed_ms = 0.0;
        double max_elapsed_ms = 0.0;
        int have_success_timing = 0;

        size_t total_samples = 0;

        for (int i = 0; i < threads; i++) {
                total_count += stats[i].total_count;
                success_count += stats[i].success_count;
                failure_count += stats[i].failure_count;
                if (stats[i].success_count > 0) {
                        if (!have_success_timing || stats[i].min_elapsed_ms < min_elapsed_ms)
                                min_elapsed_ms = stats[i].min_elapsed_ms;
                        if (!have_success_timing || stats[i].max_elapsed_ms > max_elapsed_ms)
                                max_elapsed_ms = stats[i].max_elapsed_ms;
                        have_success_timing = 1;
                }
                total_samples += (size_t)stats[i].sample_count;
        }

        const double avg_total_per_s = (elapsed_s > 0.0) ? ((double)total_count / elapsed_s) : 0.0;
        const double avg_success_per_s = (elapsed_s > 0.0) ? ((double)success_count / elapsed_s) : 0.0;

        const double avg_total_per_s_per_thread =
                (threads > 0) ? (avg_total_per_s / (double)threads) : 0.0;
        const double avg_success_per_s_per_thread =
                (threads > 0) ? (avg_success_per_s / (double)threads) : 0.0;

        double p50 = 0.0, p95 = 0.0, p99 = 0.0;
        int have_percentiles = 0;
        if (enable_percentiles && total_samples > 0) {
                double *merged = (double *)malloc(total_samples * sizeof(double));
                if (merged) {
                        size_t k = 0;
                        for (int i = 0; i < threads; i++) {
                                for (int j = 0; j < stats[i].sample_count; j++)
                                        merged[k++] = stats[i].samples[j];
                        }
                        qsort(merged, k, sizeof(double), cmp_double_asc);
                        p50 = percentile_nearest_rank(merged, k, 0.50);
                        p95 = percentile_nearest_rank(merged, k, 0.95);
                        p99 = percentile_nearest_rank(merged, k, 0.99);
                        have_percentiles = 1;
                        free(merged);
                }
        }

        pthread_barrier_destroy(&shared.barrier);
        for (int i = 0; i < threads; i++)
                free(stats[i].samples);
        free(tids);
        free(stats);

        out->threads = threads;
        out->serialized = g_serialized ? 1 : 0;
        out->duration_seconds = duration_seconds;
        out->actual_elapsed_s = elapsed_s;
        out->total_count = total_count;
        out->success_count = success_count;
        out->failure_count = failure_count;
        out->avg_total_per_s = avg_total_per_s;
        out->avg_success_per_s = avg_success_per_s;
        out->avg_total_per_s_per_thread = avg_total_per_s_per_thread;
        out->avg_success_per_s_per_thread = avg_success_per_s_per_thread;
        out->have_success_timing = have_success_timing;
        out->min_elapsed_ms = min_elapsed_ms;
        out->max_elapsed_ms = max_elapsed_ms;
        out->have_percentiles = have_percentiles;
        out->p50_ms = p50;
        out->p95_ms = p95;
        out->p99_ms = p99;
        out->samples_used = total_samples;
        return 0;
}

static int parse_sweep_list(const char *list, int **out_values, size_t *out_count)
{
        if (!list || !out_values || !out_count)
                return -1;

        char *copy = strdup(list);
        if (!copy)
                return -1;

        size_t cap = 16;
        size_t count = 0;
        int *vals = (int *)malloc(cap * sizeof(int));
        if (!vals) {
                free(copy);
                return -1;
        }

        char *saveptr = NULL;
        char *tok = strtok_r(copy, ",", &saveptr);
        while (tok) {
                while (*tok == ' ' || *tok == '\t')
                        tok++;
                if (*tok == '\0') {
                        tok = strtok_r(NULL, ",", &saveptr);
                        continue;
                }
                char *endptr = NULL;
                long v = strtol(tok, &endptr, 10);
                if (endptr == tok || (*endptr != '\0' && *endptr != ' ' && *endptr != '\t') || v <= 0 || v > 1024) {
                        free(vals);
                        free(copy);
                        return -1;
                }
                if (count == cap) {
                        cap *= 2;
                        int *nv = (int *)realloc(vals, cap * sizeof(int));
                        if (!nv) {
                                free(vals);
                                free(copy);
                                return -1;
                        }
                        vals = nv;
                }
                vals[count++] = (int)v;
                tok = strtok_r(NULL, ",", &saveptr);
        }

        free(copy);
        if (count == 0) {
                free(vals);
                return -1;
        }
        *out_values = vals;
        *out_count = count;
        return 0;
}

int main(int argc, char *argv[])
{
        int duration_seconds = 1;
        int threads = 1;
        int enable_percentiles = 0;
        int max_samples = 200000;
        const char *sweep_list = NULL;
        const char *csv_path = NULL;
        int both_modes = 0;
        int quiet = 0;

        for (int i = 1; i < argc; i++) {
                if ((strcmp(argv[i], "-d") == 0) && (i + 1 < argc)) {
                        char *endptr = NULL;
                        long v = strtol(argv[i + 1], &endptr, 10);
                        if (endptr == argv[i + 1] || *endptr != '\0' || v <= 0 || v > 3600) {
                                fprintf(stderr, "Invalid duration seconds: %s\n", argv[i + 1]);
                                usage(argv[0]);
                                return 2;
                        }
                        duration_seconds = (int)v;
                        i++;
                } else if ((strcmp(argv[i], "-n") == 0) && (i + 1 < argc)) {
                        char *endptr = NULL;
                        long v = strtol(argv[i + 1], &endptr, 10);
                        if (endptr == argv[i + 1] || *endptr != '\0' || v <= 0 || v > 1024) {
                                fprintf(stderr, "Invalid threads: %s\n", argv[i + 1]);
                                usage(argv[0]);
                                return 2;
                        }
                        threads = (int)v;
                        i++;
                } else if (strcmp(argv[i], "--serialized") == 0) {
                        g_serialized = 1;
                } else if (strcmp(argv[i], "--percentiles") == 0) {
                        enable_percentiles = 1;
                } else if ((strcmp(argv[i], "--max-samples") == 0) && (i + 1 < argc)) {
                        char *endptr = NULL;
                        long v = strtol(argv[i + 1], &endptr, 10);
                        if (endptr == argv[i + 1] || *endptr != '\0' || v <= 0 || v > 20000000) {
                                fprintf(stderr, "Invalid max samples: %s\n", argv[i + 1]);
                                usage(argv[0]);
                                return 2;
                        }
                        max_samples = (int)v;
                        i++;
                } else if ((strcmp(argv[i], "--sweep") == 0) && (i + 1 < argc)) {
                        sweep_list = argv[i + 1];
                        i++;
                } else if ((strcmp(argv[i], "--csv") == 0) && (i + 1 < argc)) {
                        csv_path = argv[i + 1];
                        i++;
                } else if (strcmp(argv[i], "--both-modes") == 0) {
                        both_modes = 1;
                } else if (strcmp(argv[i], "--quiet") == 0) {
                        quiet = 1;
                } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
                        usage(argv[0]);
                        return 0;
                } else {
                        fprintf(stderr, "Unknown argument: %s\n", argv[i]);
                        usage(argv[0]);
                        return 2;
                }
        }

        if (sweep_list) {
                int *vals = NULL;
                size_t val_count = 0;
                if (parse_sweep_list(sweep_list, &vals, &val_count) != 0) {
                        fprintf(stderr, "Invalid --sweep list: %s\n", sweep_list);
                        return 2;
                }

                FILE *csv = stdout;
                if (csv_path) {
                        csv = fopen(csv_path, "w");
                        if (!csv) {
                                fprintf(stderr, "Failed to open CSV path %s: %s\n", csv_path, strerror(errno));
                                free(vals);
                                return 1;
                        }
                }

                fprintf(csv,
                        "threads,mode,duration_s,actual_elapsed_s,total,success,failure,avg_total_per_s,avg_success_per_s,avg_total_per_s_per_thread,avg_success_per_s_per_thread,min_ms,max_ms,p50_ms,p95_ms,p99_ms,samples\n");

                for (size_t idx = 0; idx < val_count; idx++) {
                        int n = vals[idx];
                        int modes = both_modes ? 2 : 1;
                        for (int m = 0; m < modes; m++) {
                                if (both_modes) {
                                        g_serialized = (m == 1) ? 1 : 0;
                                }
                                bench_result_t r;
                                if (run_once(duration_seconds, n, enable_percentiles, max_samples,
                                             quiet ? 1 : 0, &r) != 0) {
                                        fprintf(stderr, "Run failed for -n %d mode %s\n", n,
                                                g_serialized ? "serialized" : "concurrent");
                                        continue;
                                }

                                fprintf(csv,
                                        "%d,%s,%d,%.3f,%d,%d,%d,%.2f,%.2f,%.2f,%.2f,",
                                        r.threads,
                                        r.serialized ? "serialized" : "concurrent",
                                        r.duration_seconds,
                                        r.actual_elapsed_s,
                                        r.total_count,
                                        r.success_count,
                                        r.failure_count,
                                        r.avg_total_per_s,
                                        r.avg_success_per_s,
                                        r.avg_total_per_s_per_thread,
                                        r.avg_success_per_s_per_thread);

                                if (r.have_success_timing)
                                        fprintf(csv, "%.2f,%.2f,", r.min_elapsed_ms, r.max_elapsed_ms);
                                else
                                        fprintf(csv, ",,");

                                if (r.have_percentiles)
                                        fprintf(csv, "%.2f,%.2f,%.2f,", r.p50_ms, r.p95_ms, r.p99_ms);
                                else
                                        fprintf(csv, ",,,");

                                fprintf(csv, "%zu\n", r.samples_used);
                                fflush(csv);
                        }
                }

                if (csv_path)
                        fclose(csv);
                free(vals);
                return 0;
        }

        bench_result_t r;
        if (run_once(duration_seconds, threads, enable_percentiles, max_samples, 0, &r) != 0)
                return 1;

        printf("\nSummary (tdx_att_get_quote)\n");
        printf("Threads: %d\n", r.threads);
        printf("Mode: %s\n", r.serialized ? "serialized" : "concurrent");
        printf("Duration: requested %d s, actual %.3f s\n", r.duration_seconds, r.actual_elapsed_s);
        printf("Total:   %d\n", r.total_count);
        printf("Success: %d\n", r.success_count);
        printf("Failure: %d\n", r.failure_count);
        printf("Avg total per 1s:   %.2f\n", r.avg_total_per_s);
        printf("Avg success per 1s: %.2f\n", r.avg_success_per_s);
        printf("Avg total per 1s per thread:   %.2f\n", r.avg_total_per_s_per_thread);
        printf("Avg success per 1s per thread: %.2f\n", r.avg_success_per_s_per_thread);
        if (r.have_success_timing) {
                printf("Min elapsed_time: %.2f ms\n", r.min_elapsed_ms);
                printf("Max elapsed_time: %.2f ms\n", r.max_elapsed_ms);
        } else {
                printf("Min elapsed_time: N/A\n");
                printf("Max elapsed_time: N/A\n");
        }

        if (enable_percentiles) {
                if (r.have_percentiles) {
                        printf("Latency percentiles (ms, success-only): P50=%.2f P95=%.2f P99=%.2f\n",
                               r.p50_ms, r.p95_ms, r.p99_ms);
                        printf("Percentile samples used: %zu (cap=%d)\n", r.samples_used, max_samples);
                } else {
                        printf("Latency percentiles: N/A (no samples)\n");
                }
        }

        return 0;
}


