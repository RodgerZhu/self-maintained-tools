Compile the code under Ubuntu 24.04 with libtdx-attest installed.

./td_quote_test -d 20 -n 25 --percentiles
Start tdx_att_get_quote concurrent loop, duration: 20 s, threads: 25

Summary (tdx_att_get_quote)
Threads: 25
Mode: concurrent
Duration: requested 20 s, actual 20.004 s
Total:   140282
Success: 140282
Failure: 0
Avg total per 1s:   7012.84
Avg success per 1s: 7012.84
Avg total per 1s per thread:   280.51
Avg success per 1s per thread: 280.51
Min elapsed_time: 2.56 ms
Max elapsed_time: 13.65 ms
Latency percentiles (ms, success-only): P50=3.52 P95=3.98 P99=4.35
Percentile samples used: 140282 (cap=200000)

