#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 4 ]]; then
  echo "Usage: $0 <pid> [output_csv] [interval_seconds] [session_start_epoch]" >&2
  exit 1
fi

profile_pid="$1"
output_file="${2:-profiling/$(date +%Y%m%d_%H%M%S)/memory.csv}"
interval_seconds="${3:-1}"
session_start_epoch="${4:-$(date +%s.%N)}"

mkdir -p "$(dirname "$output_file")"

if ! kill -0 "$profile_pid" 2>/dev/null; then
  echo "Process $profile_pid is not running" >&2
  exit 1
fi

printf '%s\n' \
  "timestamp_epoch,elapsed_sec,rss_kb,rss_anon_kb,rss_file_kb,rss_shmem_kb,pss_kb,private_clean_kb,private_dirty_kb,shared_clean_kb,shared_dirty_kb,anonymous_kb,lazy_free_kb,anon_huge_pages_kb,swap_kb,vm_size_kb,vm_data_kb,vm_swap_kb,threads,fd_count,minflt,majflt,utime_ticks,stime_ticks,read_bytes,write_bytes,voluntary_ctxt_switches,nonvoluntary_ctxt_switches,process_vram_kb,process_gtt_kb,global_vram_used_kb,global_gtt_used_kb" \
  > "$output_file"

shopt -s nullglob
vram_used_paths=(/sys/class/drm/card*/device/mem_info_vram_used)
gtt_used_paths=(/sys/class/drm/card*/device/mem_info_gtt_used)

read_proc_values() {
  local status_file="/proc/$profile_pid/status"
  local smaps_file="/proc/$profile_pid/smaps_rollup"
  local stat_file="/proc/$profile_pid/stat"
  local io_file="/proc/$profile_pid/io"
  local status_values smaps_values stat_values io_values
  local process_vram_gtt global_vram global_gtt
  local fd_paths

  status_values="$(awk '
    BEGIN {
      keys["VmRSS:"]="rss"; keys["RssAnon:"]="anon"; keys["RssFile:"]="file";
      keys["RssShmem:"]="shmem"; keys["VmSize:"]="vmsize"; keys["VmData:"]="vmdata";
      keys["VmSwap:"]="vmswap"; keys["Threads:"]="threads";
      keys["voluntary_ctxt_switches:"]="vctx"; keys["nonvoluntary_ctxt_switches:"]="nvctx";
    }
    $1 in keys { value[keys[$1]]=$2 }
    END {
      printf "%d,%d,%d,%d,%d,%d,%d,%d,%d",
        value["rss"], value["anon"], value["file"], value["shmem"],
        value["vmsize"], value["vmdata"], value["vmswap"], value["threads"],
        value["vctx"];
      printf ",%d", value["nvctx"];
    }
  ' "$status_file" 2>/dev/null)" || return 1

  if [[ -r "$smaps_file" ]]; then
    smaps_values="$(awk '
      BEGIN {
        keys["Pss:"]="pss"; keys["Private_Clean:"]="pclean";
        keys["Private_Dirty:"]="pdirty"; keys["Shared_Clean:"]="sclean";
        keys["Shared_Dirty:"]="sdirty"; keys["Anonymous:"]="anonymous";
        keys["LazyFree:"]="lazy"; keys["AnonHugePages:"]="huge"; keys["Swap:"]="swap";
      }
      $1 in keys { value[keys[$1]]=$2 }
      END {
        printf "%d,%d,%d,%d,%d,%d,%d,%d,%d",
          value["pss"], value["pclean"], value["pdirty"], value["sclean"],
          value["sdirty"], value["anonymous"], value["lazy"], value["huge"],
          value["swap"];
      }
    ' "$smaps_file" 2>/dev/null)" || smaps_values="0,0,0,0,0,0,0,0,0"
  else
    smaps_values="0,0,0,0,0,0,0,0,0"
  fi

  stat_values="$(awk '
    {
      sub(/^.*\) /, "");
      printf "%d,%d,%d,%d", $8, $10, $12, $13;
    }
  ' "$stat_file" 2>/dev/null)" || return 1

  if [[ -r "$io_file" ]]; then
    io_values="$(awk '
      $1=="read_bytes:" { read_bytes=$2 }
      $1=="write_bytes:" { write_bytes=$2 }
      END { printf "%d,%d", read_bytes, write_bytes }
    ' "$io_file" 2>/dev/null)" || io_values="0,0"
  else
    io_values="0,0"
  fi

  fd_paths=(/proc/"$profile_pid"/fd/*)
  local fd_count="${#fd_paths[@]}"

  local fdinfo_paths=(/proc/"$profile_pid"/fdinfo/*)
  if ((${#fdinfo_paths[@]})); then
    process_vram_gtt="$(awk '
      function kib(value, unit) {
        if (unit=="MiB") return value*1024;
        if (unit=="GiB") return value*1024*1024;
        if (unit=="B") return value/1024;
        return value;
      }
      function flush_client() {
        if (client=="" && (client_vram || client_gtt)) client=previous_file;
        if (client!="" && !seen[client]++) {
          total_vram += client_vram;
          total_gtt += client_gtt;
        }
        client="";
        client_vram=0;
        client_gtt=0;
      }
      FNR==1 {
        flush_client();
        previous_file=FILENAME;
      }
      $1=="drm-client-id:" { client=$2 }
      $1=="drm-memory-vram:" { client_vram += kib($2, $3) }
      $1=="drm-memory-gtt:" { client_gtt += kib($2, $3) }
      END {
        flush_client();
        printf "%.0f,%.0f", total_vram, total_gtt;
      }
    ' "${fdinfo_paths[@]}" 2>/dev/null)" || process_vram_gtt="0,0"
  else
    process_vram_gtt="0,0"
  fi

  global_vram=0
  local memory_path memory_bytes
  for memory_path in "${vram_used_paths[@]}"; do
    if [[ -r "$memory_path" ]]; then
      read -r memory_bytes < "$memory_path" || memory_bytes=0
      global_vram=$((global_vram + memory_bytes / 1024))
    fi
  done

  global_gtt=0
  for memory_path in "${gtt_used_paths[@]}"; do
    if [[ -r "$memory_path" ]]; then
      read -r memory_bytes < "$memory_path" || memory_bytes=0
      global_gtt=$((global_gtt + memory_bytes / 1024))
    fi
  done

  local rss rss_anon rss_file rss_shmem vm_size vm_data vm_swap threads vctx nvctx
  IFS=, read -r rss rss_anon rss_file rss_shmem vm_size vm_data vm_swap threads vctx nvctx <<< "$status_values"

  local pss private_clean private_dirty shared_clean shared_dirty anonymous lazy_free anon_huge swap
  IFS=, read -r pss private_clean private_dirty shared_clean shared_dirty anonymous lazy_free anon_huge swap <<< "$smaps_values"

  local minflt majflt utime stime
  IFS=, read -r minflt majflt utime stime <<< "$stat_values"

  local read_bytes write_bytes
  IFS=, read -r read_bytes write_bytes <<< "$io_values"

  local process_vram process_gtt
  IFS=, read -r process_vram process_gtt <<< "$process_vram_gtt"

  printf '%s' "$rss,$rss_anon,$rss_file,$rss_shmem,$pss,$private_clean,$private_dirty,$shared_clean,$shared_dirty,$anonymous,$lazy_free,$anon_huge,$swap,$vm_size,$vm_data,$vm_swap,$threads,$fd_count,$minflt,$majflt,$utime,$stime,$read_bytes,$write_bytes,$vctx,$nvctx,$process_vram,$process_gtt,$global_vram,$global_gtt"
}

while kill -0 "$profile_pid" 2>/dev/null; do
  timestamp_epoch="$(date +%s.%N)"
  elapsed_sec="$(awk -v now="$timestamp_epoch" -v start="$session_start_epoch" 'BEGIN { printf "%.6f", now-start }')"
  if values="$(read_proc_values)"; then
    printf '%s,%s,%s\n' "$timestamp_epoch" "$elapsed_sec" "$values" >> "$output_file"
  fi
  sleep "$interval_seconds"
done
