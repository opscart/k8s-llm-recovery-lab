awk -F, '
NR > 1 {
  n++

  trivial += $2
  health_wall += $3
  health_internal += $4
  overhead += $5

  trivial_sq += $2 * $2
  health_wall_sq += $3 * $3
  health_internal_sq += $4 * $4
  overhead_sq += $5 * $5

  if (n == 1 || $2 < trivial_min) trivial_min = $2
  if (n == 1 || $2 > trivial_max) trivial_max = $2

  if (n == 1 || $5 < overhead_min) overhead_min = $5
  if (n == 1 || $5 > overhead_max) overhead_max = $5
}
END {
  if (n < 1) exit 1

  trivial_mean = trivial / n
  health_wall_mean = health_wall / n
  health_internal_mean = health_internal / n
  overhead_mean = overhead / n

  if (n > 1) {
    trivial_sd = sqrt((trivial_sq - n * trivial_mean * trivial_mean) / (n - 1))
    health_wall_sd = sqrt((health_wall_sq - n * health_wall_mean * health_wall_mean) / (n - 1))
    health_internal_sd = sqrt((health_internal_sq - n * health_internal_mean * health_internal_mean) / (n - 1))
    overhead_sd = sqrt((overhead_sq - n * overhead_mean * overhead_mean) / (n - 1))
  } else {
    trivial_sd = 0
    health_wall_sd = 0
    health_internal_sd = 0
    overhead_sd = 0
  }

  printf "n=%d\n", n

  printf "trivial_exec_mean_ms=%.3f\n", trivial_mean
  printf "trivial_exec_sd_ms=%.3f\n", trivial_sd
  printf "trivial_exec_min_ms=%.3f\n", trivial_min
  printf "trivial_exec_max_ms=%.3f\n", trivial_max

  printf "health_exec_wall_mean_ms=%.3f\n", health_wall_mean
  printf "health_exec_wall_sd_ms=%.3f\n", health_wall_sd

  printf "health_internal_mean_ms=%.3f\n", health_internal_mean
  printf "health_internal_sd_ms=%.3f\n", health_internal_sd

  printf "estimated_exec_overhead_mean_ms=%.3f\n", overhead_mean
  printf "estimated_exec_overhead_sd_ms=%.3f\n", overhead_sd
  printf "estimated_exec_overhead_min_ms=%.3f\n", overhead_min
  printf "estimated_exec_overhead_max_ms=%.3f\n", overhead_max
}
' "${OUT_ROOT}/summary.csv" \
  | tee "${OUT_ROOT}/statistics.txt"